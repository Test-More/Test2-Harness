package Test2::Formatter::Stream;
use strict;
use warnings;

our $VERSION = '1.000000';

use Carp qw/croak confess/;
use Time::HiRes qw/time/;
use IO::Handle;
use File::Spec();

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/JSON JSON_IS_XS/;
use Test2::Harness::Util qw/hub_truth apply_encoding/;

use Test2::Util qw/get_tid ipc_separator/;

use base qw/Test2::Formatter/;
use Test2::Util::HashBase qw/-io _encoding _no_header _no_numbers _no_diag -stream_id -tb -tb_handles -dir -_pid -_tid -_fh <job_id/;

BEGIN {
    my $J = JSON->new;
    $J->indent(0);
    $J->convert_blessed(1);
    $J->allow_blessed(1);
    $J->utf8(1);

    require constant;
    constant->import(ENCODER => $J);

    if (JSON_IS_XS) {
        require JSON::PP;
        my $JPP = JSON::PP->new;
        $JPP->indent(0);
        $JPP->convert_blessed(1);
        $JPP->allow_blessed(1);
        $JPP->utf8(1);

        constant->import(ENCODER_PP => $JPP);
    }
}

my ($ROOT_TID, $ROOT_PID, $ROOT_DIR, $ROOT_JOB_ID);
sub import {
    my $class = shift;
    my %params = @_;

    confess "$class no longer accept the 'file' argument, it now takes a 'dir' argument"
        if exists $params{file};

    $class->SUPER::import();

    $ROOT_PID  = $$;
    $ROOT_TID  = get_tid();
    $ROOT_DIR = $params{dir} if $params{dir};
    $ROOT_JOB_ID = $params{job_id} if $params{job_id};
}

sub hide_buffered { 0 }

sub fh {
    my $self = shift;

    my $dir = $self->{+DIR} or return undef;

    my $pid = $self->{+_PID};
    my $tid = $self->{+_TID};

    if ($pid && $pid != $$) {
        delete $self->{+_PID};
        delete $self->{+_FH};
    }

    if ($tid && $tid != get_tid()) {
        delete $self->{+_TID};
        delete $self->{+_FH};
    }

    return $self->{+_FH} if $self->{+_FH};

    $self->{+STREAM_ID} = 1;

    $pid = $self->{+_PID} = $$;
    $tid = $self->{+_TID} = get_tid();

    my $file = File::Spec->catfile($dir, join(ipc_separator() => 'events', $pid, $tid) . ".jsonl");

    mkdir($dir) or die "Could not make dir '$dir': $!" unless -d $dir;
    confess "File '$file' already exists!" if -f $file;
    open(my $fh, '>', $file) or die "Could not open file: $file";
    $fh->autoflush(1);

    # Do not apply encoding to the UTF8 output, we let the utf8 formatter
    # handle that. This means do not apply encoding to $self->{+_FH}.

    return $self->{+_FH} = $fh;
}

sub init {
    my $self = shift;

    $self->{+STREAM_ID} = 1;

    for (@{$self->{+IO}}) {
        $_->autoflush(1);
    }

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stdout()->autoflush(1);
        Test2::API::test2_stderr()->autoflush(1);
    }

    if ($self->{check_tb}) {
        require Test::Builder::Formatter;
        $self->{+TB} = Test::Builder::Formatter->new();
        $self->{+TB_HANDLES} = [@{$self->{+TB}->handles}];
    }
}

sub new_root {
    my $class = shift;
    my %params = @_;

    $ROOT_PID = $$ unless defined $ROOT_PID;
    $ROOT_TID = get_tid() unless defined $ROOT_TID;

    confess "new_root called from child process!"
        if $ROOT_PID != $$;

    confess "new_root called from child thread!"
        if $ROOT_TID != get_tid();

    require Test2::API;
    my $io = $params{+IO} = [Test2::API::test2_stdout(), Test2::API::test2_stderr()];
    $_->autoflush(1) for @$io;

    confess "T2_STREAM_FILE is no longer used, see T2_STREAM_DIR"
        if exists $ENV{T2_STREAM_FILE};

    $params{+DIR} ||= $ENV{T2_STREAM_DIR} || $ROOT_DIR;
    $params{+JOB_ID} ||= $ENV{T2_STREAM_JOB_ID} || $ROOT_JOB_ID || 1;


    if ($ENV{FAIL_ONCE}) {
        no warnings 'uninitialized';
        print STDERR "T2_FORMATTER: $ENV{T2_FORMATTER}\n";
        print STDERR "T2_STREAM_DIR: $ENV{T2_STREAM_DIR}\n";
        print STDERR "T2_STREAM_JOB_ID: $ENV{T2_STREAM_JOB_ID}\n";
    }

    # DO NOT REOPEN THEM!
    delete $ENV{T2_FORMATTER} if $ENV{T2_FORMATTER} && $ENV{T2_FORMATTER} eq 'Stream';
    delete $ENV{T2_STREAM_DIR};
    delete $ENV{T2_STREAM_JOB_ID};
    $ROOT_DIR = undef;

    $params{check_tb} = 1 if $INC{'Test/Builder.pm'};

    return $class->new(%params);
}

sub record {
    my $self = shift;
    my ($facets, $num) = @_;

    my $stamp = time;
    my $times = [times];

    my @sync = @{$self->{+IO}};
    my $leader = 0;

    my $fh = $self->fh;
    unless($fh) {
        $leader = 1;
        $fh = shift @sync;
    }

    if ($facets->{control}->{halt}) {
        my $reason = $facets->{control}->{details} || "";

        if ($leader) {
            print $fh "\nBail out!  $reason\n";
        }
        else {
            open(my $bh, '>', File::Spec->catfile($self->{+DIR}, 'bail')) or die "Could not create bail file: $!";
            print $bh $reason;
            close($bh);
        }
    }

    my $tid = get_tid();
    my $id = $self->{+STREAM_ID}++;

    my $json;
    {
        no warnings 'once';
        local *UNIVERSAL::TO_JSON = sub { "$_[0]" };

        my $event_id = $facets->{about}->{uuid} ||= gen_uuid();

        if (JSON_IS_XS) {
            for my $encoder (ENCODER, ENCODER_PP) {
                local $@;
                my $ok = eval {
                    $json = $encoder->encode(
                        {
                            stamp        => $stamp,
                            times        => $times,
                            stream_id    => $id,
                            tid          => $tid,
                            pid          => $$,
                            event_id     => $event_id,
                            facet_data   => $facets,
                            assert_count => $self->{+_NO_NUMBERS} ? undef : $num,
                        }
                    );
                    1;
                };
                my $err = $@;
                last if $ok;

                # Intercept bug in JSON::XS so we can fall back to JSON::PP
                next if $encoder eq ENCODER && $err =~ m/Modification of a read-only value attempted/;

                # Different error, time to die.
                die $err;
            }
        }
        else {
            $json = ENCODER->encode(
                {
                    stamp        => $stamp,
                    times        => $times,
                    stream_id    => $id,
                    tid          => $tid,
                    pid          => $$,
                    event_id     => $event_id,
                    facet_data   => $facets,
                    assert_count => $self->{+_NO_NUMBERS} ? undef : $num,
                }
            );
        }
    }

    # Local is expensive! Only do it if we really need to.
    local($\, $,) = (undef, '') if $\ || $,;

    my $job_id = $self->{+JOB_ID};

    print $fh $leader ? ("T2-HARNESS-$job_id-EVENT: ", $json, "\n") : ($json, "\n");

    print $_ "T2-HARNESS-$job_id-ESYNC: ", join(ipc_separator() => $$, $tid, $id) . "\n" for @sync;
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;
        $self->record({control => {encoding => $enc}});
        $self->_set_encoding($enc);
        $self->{+TB}->encoding($enc) if $self->{+TB};
    }

    return $self->{+_ENCODING};
}

sub _set_encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;

        # Do not apply encoding to the UTF8 output, we let the utf8 formatter
        # handle that. This means do not apply encoding to $self->{+_FH}.

        apply_encoding(\*STDOUT, $enc);
        apply_encoding(\*STDERR, $enc);

        my $job_id = $self->{+JOB_ID};
        for my $fh (@{$self->{+IO}}) {
            print $fh "T2-HARNESS-$job_id-ENCODING: $enc\n";
            apply_encoding($fh, $enc);
        }
    }

    return $self->{+_ENCODING};
}

if ($^C) {
    no warnings 'redefine';
    *write = sub { };
}

sub write {
    my ($self, $e, $num, $f) = @_;
    $f ||= $e->facet_data;

    $self->_set_encoding($f->{control}->{encoding}) if $f->{control}->{encoding};

    # Hide these if we must, but do not remove them for good.
    local $f->{info} if $self->{+_NO_DIAG};
    local $f->{plan} if $self->{+_NO_HEADER};

    my $tb_only = 0;
    if ($self->{+TB}) {
        $tb_only ||= $self->{+TB_HANDLES}->[0] != $self->{+TB}->{handles}->[0];
        $tb_only ||= $self->{+TB_HANDLES}->[1] != $self->{+TB}->{handles}->[1];

        my $todo_match = $self->{+TB_HANDLES}->[0] == $self->{+TB}->{handles}->[2]
            || $self->{+TB_HANDLES}->[1] == $self->{+TB}->{handles}->[2];

        $tb_only ||= !$todo_match;

        if ($tb_only) {
            my $buffered = hub_truth($f)->{buffered};
            $self->{+TB}->write($e, $num, $f) if $self->{+TB} && !$buffered;
            return;
        }
    }

    $self->record($f, $num);
}

sub no_header  { $_[0]->{+_NO_HEADER} }
sub no_diag    { $_[0]->{+_NO_DIAG} }
sub no_numbers { $_[0]->{+_NO_NUMBERS} }

sub handles {
    my $self = shift;

    return $self->{+TB}->handles if $self->{+TB};
    return;
}

sub set_no_header {
    my $self = shift;
    ($self->{+_NO_HEADER}) = @_;
    $self->{+TB}->set_no_header(@_) if $self->{+TB};
    $self->{+_NO_HEADER};
}

sub set_no_diag {
    my $self = shift;
    ($self->{+_NO_DIAG}) = @_;
    $self->{+TB}->set_no_diag(@_) if $self->{+TB};
    $self->{+_NO_DIAG};
}

sub set_no_numbers {
    my $self = shift;
    ($self->{+_NO_NUMBERS}) = @_;
    $self->{+TB}->set_no_numbers(@_) if $self->{+TB};
    $self->{+_NO_NUMBERS};
}

sub set_handles {
    my $self = shift;
    return $self->{+TB}->set_handles(@_) if $self->{+TB};
    return;
}

sub terminate {
    my $self = shift;
    return $self->SUPER::terminate(@_) unless $self->{+TB};
    return $self->{+TB}->terminate(@_);
}

sub finalize {
    my $self = shift;
    return $self->SUPER::finalize(@_) unless $self->{+TB};
    return $self->{+TB}->finalize(@_);
}

sub DESTROY {}

our $AUTOLOAD;

sub AUTOLOAD {
    my $this = shift;

    my $meth = $AUTOLOAD;
    $meth =~ s/^.*:://g;

    my $type = ref($this);

    return $this->{+TB}->$meth(@_)
        if $type && $this->{+TB} && $this->{+TB}->can($meth);

    $type ||= $this;
    croak qq{Can't locate object method "$meth" via package "$type"};
}

sub isa {
    my $in = shift;
    return $in->SUPER::isa(@_) unless ref($in) && $in->{+TB};
    return $in->SUPER::isa(@_) || $in->{+TB}->isa(@_);
}

sub can {
    my $in = shift;
    return $in->SUPER::can(@_) unless ref($in) && $in->{+TB};
    return $in->SUPER::can(@_) || $in->{+TB}->can(@_);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Stream - Test2 Formatter that directly writes events.

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
