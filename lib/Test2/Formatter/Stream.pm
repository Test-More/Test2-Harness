package Test2::Formatter::Stream;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/croak confess/;
use Time::HiRes qw/time/;
use IO::Handle;
use File::Spec();
use List::Util qw/first/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/JSON JSON_IS_XS/;
use Test2::Harness::Util qw/hub_truth apply_encoding/;

use Test2::Plugin::UUID;

use Test2::Util qw/get_tid ipc_separator/;

use Atomic::Pipe;

use base qw/Test2::Formatter/;
use Test2::Util::HashBase qw{
    <io

    _encoding
    _no_header
    _no_numbers
    _no_diag

    <tb <tb_handles

    <pid <tid

    <job_id
};

sub hide_buffered { 0 }

BEGIN {
    my $J = JSON->new;
    $J->indent(0);
    $J->convert_blessed(1);
    $J->allow_blessed(1);
    $J->utf8(1);
    $J->ascii(1);

    require constant;
    constant->import(ENCODER => $J);

    if (JSON_IS_XS) {
        require JSON::PP;
        my $JPP = JSON::PP->new;
        $JPP->indent(0);
        $JPP->convert_blessed(1);
        $JPP->allow_blessed(1);
        $JPP->utf8(1);
        $JPP->ascii(1);

        constant->import(ENCODER_PP => $JPP);
    }
}

my ($ROOT_TID, $ROOT_PID, $ROOT_JOB_ID);
sub import {
    my $class = shift;
    my %params = @_;

    $class->SUPER::import();

    $ROOT_PID    = $$;
    $ROOT_TID    = get_tid();
    $ROOT_JOB_ID = $params{job_id} if $params{job_id};
}

sub init {
    my $self = shift;

    $self->{+PID} = $$;
    $self->{+TID} = get_tid();

    if ($self->{check_tb}) {
        require Test::Builder::Formatter;
        $self->{+TB} = Test::Builder::Formatter->new();
        $self->{+TB_HANDLES} = [@{$self->{+TB}->handles}];
    }
}

sub new_root {
    my $class = shift;
    my %params = @_;

    $ROOT_PID //= $$;
    $ROOT_TID //= get_tid();

    confess "new_root called from child process!"
        if $ROOT_PID != $$;

    confess "new_root called from child thread!"
        if $ROOT_TID != get_tid();

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    require Test2::API;
    Test2::API::test2_stdout()->autoflush(1);
    Test2::API::test2_stderr()->autoflush(1);

    die "STDOUT is not connected to a pipe" unless -p STDOUT;
    die "STDERR is not connected to a pipe" unless -p STDERR;

    my $io = $params{+IO} = [
        Atomic::Pipe->from_fh('>&', \*STDOUT),
        Atomic::Pipe->from_fh('>&', \*STDERR),
    ];

    my $job_id = $params{+JOB_ID} //= $ENV{T2_STREAM_JOB_ID} // $ROOT_JOB_ID // 1;

    my $esync = "STREAM-ESYNC $job_id " . time . " 0";
    for my $fh (@$io) {
        $fh->set_mixed_data_mode;

        # Set the read size to the DEFAULT pipe size (before resizing) it seems
        # to be the fastest (optimizations in the kernel? memory boundary?).
        if (my $size = $fh->size) {
            $fh->read_size($size);
        }

        $fh->write_message($esync);
    }

    # DO NOT REOPEN THEM!
    delete $ENV{T2_FORMATTER} if $ENV{T2_FORMATTER} && $ENV{T2_FORMATTER} eq 'Stream';
    delete $ENV{T2_STREAM_JOB_ID};

    $params{check_tb} = 1 if $INC{'Test/Builder.pm'};

    return $class->new(%params);
}

sub record {
    my $self = shift;
    my ($facets, $num) = @_;

    my $stamp = time;

    my ($es, @sync) = @{$self->{+IO}};
    my $tid = get_tid();

    my $event_id;
    my $json;
    {
        no warnings 'once';
        local *UNIVERSAL::TO_JSON = sub { "$_[0]" };

        $event_id = $facets->{about}->{uuid} //= gen_uuid();

        confess "'stream' facet already exists in event before Stream could tag it" if $facets->{stream};

        $facets->{stream} = {
            pid       => $$,
            tid       => $tid,
            stamp     => $stamp,
            event_id  => $event_id,
        };

        $facets->{stream}->{assert_count} = $num unless $self->{+_NO_NUMBERS};

        if (JSON_IS_XS) {
            for my $encoder (ENCODER, ENCODER_PP) {
                local $@;
                my $ok  = eval { $json = $encoder->encode($facets); 1 };
                my $err = $@;
                last if $ok;

                # Intercept bug in JSON::XS so we can fall back to JSON::PP
                next if $encoder eq ENCODER && $err =~ m/Modification of a read-only value attempted/;

                # Different error, time to die.
                die $err;
            }
        }
        else {
            $json = ENCODER->encode($facets);
        }
    }

    my $job_id = $self->{+JOB_ID};

    my $esync = "STREAM-ESYNC $job_id $stamp $event_id";

    # Write the event
    $es->write_message("STREAM-EVENT $job_id $stamp " . $json);

    $_->write_message($esync) for @sync;
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

        apply_encoding(\*STDOUT, $enc);
        apply_encoding(\*STDERR, $enc);

        my $job_id = $self->{+JOB_ID};

        my $msg = "STREAM-ENCODING $job_id " . time . " $enc";
        $_->write_message($msg) for @{$self->{+IO}};
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

    # Do not write nested events in a child process/thread
    # These happen if you fork inside a subtest, start a new subtest and fork
    # again inside it.
    my $hf = hub_truth($f);
    if ($hf->{nested}) {
        return if $self->{+PID} && $self->{+PID} != $$;
        return if $self->{+TID} && $self->{+TID} != get_tid();
    }

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
            my $buffered = $hf->{buffered};
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

This formatter writes all test2 events to event files (one per process/thread)
instead of writing them to STDERR/STDOUT. It will output synchronization
messages to STDERR/STDOUT every time an event is written. From this data the
test output can be properly reconstructed in order with STDERR/STDOUT and
events mostly synced so that they appear in the correct order.

This formatter is not usually useful to humans. This formatter is used by
L<Test2::Harness> when possible to prevent the loss of data that normally
occurs when TAP is used.

=head1 SYNOPSIS

If you really want your test to output this:

    use Test2::Formatter::Stream;
    use Test2::V0;
    ...

Otherwise just use L<App::Yath> without the C<--no-stream> argument and this
formatter will be used when possible.

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
