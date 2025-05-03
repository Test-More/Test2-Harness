package Test2::Harness::Resource::JobCount;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use List::Util qw/max min/;
use Time::HiRes qw/time/;

use parent 'Test2::Harness::Resource';
use Test2::Harness::Util::HashBase qw{
    <slots
    <job_slots

    <used
    <assignments
};

sub is_job_limiter { 1 }

sub resource_name   { 'jobcount' }
sub resource_io_tag { 'JOBCOUNT' }

sub init {
    my $self = shift;
    $self->SUPER::init();

    die "'slots' is a require attribute and must be set higher to 0"     unless $self->{+SLOTS};
    die "'job_slots' is a require attribute and must be set higher to 0" unless $self->{+JOB_SLOTS};

    $self->{+USED} = 0;
    $self->{+ASSIGNMENTS} = {};
}

# Always applicable
sub applicable { 1 }

sub available {
    my $self = shift;
    my ($id, $job) = @_;

    my $run_count = $self->{+JOB_SLOTS};
    my $min_slots = $job->test_file->check_min_slots || 1;
    my $max_slots = $job->test_file->check_max_slots // $min_slots;

    return -1 if $run_count < $min_slots;
    return -1 if $self->{+SLOTS} < $min_slots;

    my $free = $self->{+SLOTS} - $self->{+USED};
    return 0 if $free < 1;
    return 0 if $free < $min_slots;

    $max_slots = $free if $max_slots < 1;

    return min($max_slots, $free);
}

sub assign {
    my $self = shift;
    my ($id, $job, $env) = @_;

    croak "'env' hash was not provided" unless $env;

    my $count = $self->available($id, $job);

    $self->{+USED} += $count;
    $self->{+ASSIGNMENTS}->{$id} = {
        job   => $job,
        count => $count,
        stamp => time,
    };

    $env->{T2_HARNESS_MY_JOB_CONCURRENCY} = $count;

    $self->send_data_event;

    return $env;
}

sub release {
    my $self = shift;
    my ($id, $job) = @_;

    my $assign = delete $self->{+ASSIGNMENTS}->{$id} or die "Invalid release ID: $id";
    my $count = $assign->{count};

    $self->{+USED} -= $count;

    $self->send_data_event;

    return $id;
}

sub status_data {
    my $self = shift;

    return [
        {
            title => "Job Slot Assignments",
            tables => [
                {
                    header => [qw/Total Used Free/],
                    rows => [[$self->{+SLOTS}, $self->{+USED}, ($self->{+SLOTS} - $self->{+USED})]],
                },
                {
                    header => [qw/Runtime Slots Name/],
                    format => [qw/duration/, undef, undef],
                    rows => [
                        (map {[(time - $_->{stamp}), $_->{count}, $_->{job}->test_file->relative]} values %{$self->{+ASSIGNMENTS} // {}}),
                    ],
                }
            ],
        }
    ];
}

1;

__END__

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Resource::JobCount - FIXME

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

