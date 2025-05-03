package Test2::Harness::Collector::IOParser::Stream;
use strict;
use warnings;

our $VERSION = '2.000005';

use Test2::Harness::Collector::TapParser qw/parse_stdout_tap parse_stderr_tap/;

use parent 'Test2::Harness::Collector::IOParser';
use Test2::Harness::Util::HashBase qw{};

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream = $io->{stream};
    my $text   = $io->{line};

    my $facets = $stream eq 'stdout' ? parse_stdout_tap($text) : parse_stderr_tap($text);

    if ($facets) {
        $event->{facet_data} = $facets;
        return;
    }

    $self->SUPER::parse_stream_line($io, $event);
}

sub parse_process_action {
    my $self = shift;
    my ($io, $event) = @_;

    $self->SUPER::parse_process_action(@_);

    my $action = $io->{action} or return;
    my $data   = $io->{$action};

    if ($action eq 'exit') {
        $event->{facet_data}->{harness_job_exit} = {
            exit  => $data->{exit}->{all},
            stamp => $data->{stamp},
        };
    }
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Collector::IOParser::Stream - FIXME

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

