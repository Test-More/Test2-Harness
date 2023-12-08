package Test2::Formatter::Stream;
use strict;
use warnings;

our $VERSION = '2.000000';

use IO::Handle;
use Atomic::Pipe;

use Carp qw/croak confess/;
use Time::HiRes qw/time/;
use Test2::Util qw/get_tid/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util qw/hub_truth apply_encoding/;

use Test2::Harness::Collector::Child qw/send_event/;

use parent qw/Test2::Formatter/;
use Test2::Util::HashBase qw{
    +encoding
    <no_header
    <no_numbers
    <no_diag
    <stream_id
    <tb
    <tb_handles
};

sub hide_buffered { 0 }

sub init {
    my $self = shift;

    $self->{+STREAM_ID} = 1;

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

sub record {
    my $self = shift;
    my ($facets, $num) = @_;

    # Local is expensive! Only do it if we really need to.
    local($\, $,) = (undef, '') if $\ || $,;

    my $id = $self->{+STREAM_ID}++;
    send_event(
        $facets,
        stream_id    => $id,
        assert_count => $self->{+NO_NUMBERS} ? undef : $num,
    );
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;
        $self->record({control => {encoding => $enc}});
        $self->_set_encoding($enc);
        $self->{+TB}->encoding($enc) if $self->{+TB};
    }

    return $self->{+ENCODING};
}

sub _set_encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;

        apply_encoding(\*STDOUT, $enc);
        apply_encoding(\*STDERR, $enc);
    }

    return $self->{+ENCODING};
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
    local $f->{info} if $self->{+NO_DIAG};
    local $f->{plan} if $self->{+NO_HEADER};

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

sub handles {
    my $self = shift;

    return $self->{+TB}->handles if $self->{+TB};
    return;
}

sub set_no_header {
    my $self = shift;
    ($self->{+NO_HEADER}) = @_;
    $self->{+TB}->set_no_header(@_) if $self->{+TB};
    $self->{+NO_HEADER};
}

sub set_no_diag {
    my $self = shift;
    ($self->{+NO_DIAG}) = @_;
    $self->{+TB}->set_no_diag(@_) if $self->{+TB};
    $self->{+NO_DIAG};
}

sub set_no_numbers {
    my $self = shift;
    ($self->{+NO_NUMBERS}) = @_;
    $self->{+TB}->set_no_numbers(@_) if $self->{+TB};
    $self->{+NO_NUMBERS};
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
