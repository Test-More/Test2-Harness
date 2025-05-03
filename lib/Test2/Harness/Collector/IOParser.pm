package Test2::Harness::Collector::IOParser;
use strict;
use warnings;

use Carp qw/confess/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase qw{
    <run_id
    <job_id
    <job_try
    <name
    <type
    <tag
};

sub parse_io {
    my $self = shift;
    my ($io) = @_;

    my $stream = $io->{stream} or confess "No Stream!";

    my $event = $self->get_event($io);

    $self->parse_stream_line($io, $event) if defined $io->{line};

    $self->normalize_event($io, $event);

    return ($event);
}

sub normalize_event {
    my $self = shift;
    my ($io, $event) = @_;

    my $stamp    = $event->{stamp}    // $event->{facet_data}->{harness}->{stamp}    // $io->{stamp}    // time;
    my $event_id = $event->{event_id} // $event->{facet_data}->{harness}->{event_id} // $io->{event_id} // gen_uuid();

    my %fields = (
        stamp    => $stamp,
        event_id => $event_id,
    );

    %fields = (
        %fields,
        run_id   => $self->{+RUN_ID},
        job_id   => $self->{+JOB_ID},
        job_try  => $self->{+JOB_TRY},
    );

    for my $field (keys %fields) {
        my $val1 = $event->{$field};
        my $val2 = $event->{facet_data}->{harness}->{$field};

        die "'$field' mismatch ($val1 vs $val2), internal inconsistency."
            if defined($val1) && defined($val2) && "$val1" ne "$val2";

        my $val = $val1 // $val2 // $fields{$field} // 0;

        $event->{$field} = $val;
        $event->{facet_data}->{harness}->{$field} = $val;
    }
}

sub get_event {
    my $self = shift;
    my ($io) = @_;

    my $event = $io->{event} // $io->{data} // {
        stamp      => $io->{stamp}    // time,
        event_id   => $io->{event_id} // gen_uuid(),
        facet_data => {},
    };

    delete $io->{event};
    delete $io->{data};

    return $event;
}

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream   = $io->{stream};
    my $ucstream = uc($stream);

    my $text = delete $io->{line};
    my $tag = $self->{+TAG} // $stream // $$;

    $event->{facet_data}->{from_stream} = { source => $ucstream, details => $text };

    push @{$event->{facet_data}->{info}} => {
        details => $text,
        tag     => $tag,
        debug   => ($ucstream eq 'STDERR' ? 1 : 0),
        peek    => $io->{peek},
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Collector::IOParser - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

