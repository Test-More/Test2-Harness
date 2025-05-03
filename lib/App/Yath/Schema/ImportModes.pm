package App::Yath::Schema::ImportModes;
use strict;
use warnings;

our $VERSION = '2.000005';

use Scalar::Util qw/blessed reftype/;
use Carp qw/croak/;

use Importer Importer => 'import';

my %MODES = (
    summary  => 5,
    qvf      => 10,
    qvfd     => 15,
    qvfds    => 17,
    complete => 20,
);

%MODES = (
    %MODES,
    map {$_ => $_} values %MODES,
);

our @EXPORT_OK = qw/event_in_mode record_all_events mode_check record_subtest_events is_mode/;

our %EXPORT_ANON = (
    '%MODES' => \%MODES,
);

sub is_mode {
    my ($mode) = @_;
    return 0 unless $mode;
    return 0 if $mode =~ m/^\d+$/;
    return 0 unless $MODES{$mode};
    return 1;
}

sub mode_check {
    my ($got, @want) = @_;
    my $g = $MODES{$got} // croak "Invalid mode: $got";

    for my $want (@want) {
        my $w = $MODES{$want} // croak "Invalid mode: $want";
        return 1 if $g == $w;
    }

    return 0;
}

sub _get_mode {
    my %params = @_;

    my $run  = $params{run};
    my $mode = $params{mode};

    croak "must specify either 'mode' or 'run'" unless $run || $mode;

    # Normalize
    $mode = $MODES{$mode} // $mode;
    croak "Invalid mode: $mode" unless $mode =~ m/^\d+$/;

    return $mode;
}

sub record_all_events {
    my %params = @_;

    my $mode = _get_mode(%params);

    my $try            = $params{try};
    my $job            = $params{job} // $try ? $try->job : undef;
    my $fail           = $params{fail};
    my $is_harness_out = $params{is_harness_out};

    croak "must specify either 'try' or 'fail' and 'is_harness_out'"
        unless $try || (defined($fail) && defined($is_harness_out));

    # Always true in complete mode
    return 1 if $mode >= $MODES{complete};

    # No events in summary
    return 0 if $mode <= $MODES{summary};

    # Job 0 (harness output) is kept in all non-summary modes
    $is_harness_out //= $job->is_harness_out;
    return 1 if $is_harness_out;

    # QVF and QVFD are all events when failing
    $fail //= $try->fail;
    return 1 if $fail && $mode >= $MODES{qvf};

    return 0;
}

sub record_subtest_events {
    my %params = @_;

    return 1 if $params{record_all_events} //= record_all_events(%params);

    my $mode = _get_mode(%params);
    return 1 if $mode >= $MODES{qvfds};

    return 0;
}

sub event_in_mode {
    my %params = @_;

    my $event = $params{event} or croak "'event' is required";

    my $record_all = $params{record_all_events} //= record_all_events(%params);
    return 1 if $record_all;

    # Only look for diag and similar for QVFD and higher
    my $mode = _get_mode(%params);
    return 0 unless $mode >= $MODES{qvfd};

    my $cols = _get_event_columns($event);

    return 1 if $mode == $MODES{qvfds} && $cols->{is_subtest} && $cols->{nested} == 0;
    return 1 if $cols->{is_diag};
    return 1 if $cols->{is_harness};
    return 1 if $cols->{is_time};

    return 0;
}

sub _get_event_columns {
    my ($event) = @_;

    return { $event->get_all_fields } if blessed($event) && $event->can('get_columns');
    return $event if (reftype($event) // '') eq 'HASH';

    croak "Invalid event: $event";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::ImportModes - FIXME

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

