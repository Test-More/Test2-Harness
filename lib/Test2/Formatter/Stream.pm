package Test2::Formatter::Stream;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness::Util::JSON qw/JSON/;

use base qw/Test2::Formatter/;
use Test2::Util::HashBase qw/-io _encoding _no_header _no_numbers _no_diag -event_id -tb -tb_handles -file -leader/;

{
    my $J = JSON->new;
    $J->indent(0);
    $J->convert_blessed(1);
    $J->allow_blessed(1);
    $J->utf8(1);

    sub ENCODER() { $J }
}

my $ROOT_FILE;
sub import {
    my $class = shift;
    my %params = @_;

    $class->SUPER::import();

    $ROOT_FILE = $params{file} if $params{file};
}

sub hide_buffered { 0 }

sub init {
    my $self = shift;

    $self->{+EVENT_ID} = 1;

    if (my $file = $self->{+FILE}) {
        open(my $fh, '>', $file) or die "Could not open file: $file";
        $fh->autoflush(1);
        unshift @{$self->{+IO}} => $fh;
        $self->{+LEADER} = 0 unless defined $self->{+LEADER};
    }

    $self->{+LEADER} = 1 unless defined $self->{+LEADER};

    croak "You must specify at least 1 filehandle for output"
        unless $self->{+IO} && @{$self->{+IO}};

    $_->autoflush(1) for @{$self->{+IO}};
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

    require Test2::API;
    my $io = $params{+IO} = [Test2::API::test2_stdout(), Test2::API::test2_stderr()];
    $_->autoflush(1) for @$io;

    $params{+FILE} ||= $ENV{T2_STREAM_FILE} || $ROOT_FILE;

    # DO NOT REOPEN THEM!
    delete $ENV{T2_STREAM_FILE};
    $ROOT_FILE = undef;

    $params{check_tb} = 1 if $INC{'Test/Builder.pm'};

    return $class->new(%params);
}

sub record {
    my $self = shift;
    my ($id, $facets, $num) = @_;

    my $json;
    {
        no warnings 'once';
        local *UNIVERSAL::TO_JSON = sub { "$_[0]" };

        $json = ENCODER->encode(
            {
                stamp        => time,
                stream_id    => $id,
                event_id     => "event-$id",
                facet_data   => $facets,
                assert_count => $self->{+_NO_NUMBERS} ? undef : $num,
            }
        );
    }

    my ($out, @sync) = @{$self->{+IO}};
    print $out $self->{+LEADER} ? ("T2-HARNESS-EVENT: ", $id, ' ', $json, "\n") : ($json, "\n");
    print $_ "T2-HARNESS-ESYNC: ", $id, "\n" for @sync;
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;
        $self->record($self->{+EVENT_ID}++, {control => {encoding => $enc}});
        $self->_set_encoding($enc);
        $self->{+TB}->encoding($enc) if $self->{+TB};
    }

    return $self->{+_ENCODING};
}

sub _set_encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;

        # https://rt.perl.org/Public/Bug/Display.html?id=31923
        # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
        # order to avoid the thread segfault.
        if ($enc =~ m/^utf-?8$/i) {
            binmode($self->{+IO}->[0], ":utf8");
            binmode($self->{+IO}->[1], ":utf8");
        }
        else {
            binmode($self->{+IO}->[0], ":encoding($enc)");
            binmode($self->{+IO}->[1], ":encoding($enc)");
        }
        $self->{+_ENCODING} = $enc;
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
            $self->{+TB}->write($e, $num, $f) if $self->{+TB} && !$f->{trace}->{buffered};
            return;
        }
    }

    my $id = $self->{+EVENT_ID}++;
    $self->record($id, $f, $num);
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

=back

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
