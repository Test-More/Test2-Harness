package Test2::Harness::Runner::Resource::JobCount;
use strict;
use warnings;

our $VERSION = '1.000134';

use parent 'Test2::Harness::Runner::Resource';
use Test2::Harness::Util::HashBase qw/<settings <job_count <used <free/;
use Time::HiRes qw/time/;
use List::Util qw/min/;

sub job_limiter { 1 }

sub new {
    my $class = shift;
    my $self = bless {@_}, $class;
    $self->init();
    return $self;
}

sub init {
    my $self = shift;
    my $settings = $self->{+SETTINGS};
    $self->{+JOB_COUNT} //= $settings ? $settings->runner->job_count // 1 : 1;
    $self->{+USED} //= {};
    $self->{+FREE} //= [1 .. $self->{+JOB_COUNT}];
}

sub job_limiter_max {
    my $self = shift;
    return $self->{+JOB_COUNT};
}

sub job_limiter_at_max {
    my $self = shift;
    return 0 if @{$self->{+FREE}};
    return 1;
}

sub available {
    my $self = shift;
    my ($task) = @_;

    my $concurrency = $task->{slots_per_job} // $self->settings->runner->slots_per_job // 1;

    return 1 if @{$self->{+FREE}} >= $concurrency;
    return 0;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;

    my $concurrency = $task->{slots_per_job} // $self->settings->runner->slots_per_job // 1;

    $state->{record} = {
        count => $concurrency,
        file  => $task->{rel_file},
        stamp => time,
    };
}

sub record {
    my $self = shift;
    my ($job_id, $info) = @_;

    my $count = $info->{count};
    my @use = splice @{$self->{+FREE}}, 0, $count;
    $info->{slots} = \@use;

    $self->{+USED}->{$job_id} = $info;
}

sub release {
    my $self = shift;
    my ($job_id) = @_;

    # Could be a free with no used slot.
    my $info = delete $self->{+USED}->{$job_id} or return;
    my $slots = $info->{slots};

    push @{$self->{+FREE}} => @$slots;
}

sub status_lines {
    my $self = shift;

    my $out = "  Job Slots:\n";

    for my $info (sort { $a->{stamp} <=> $b->{stamp} } values %{$self->{+USED}}) {
        my $slots = $info->{slots};
        my $slot_list = join ',' => sort { $a <=> $b } @$slots;
        $out .= sprintf("%12s: %8.2fs | %s\n", $slot_list, time - $info->{stamp}, $info->{file});
    }

    for my $slot (sort { $a <=> $b } @{$self->{+FREE}}) {
        $out .= sprintf("%12s: FREE\n", $slot);
    }

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Resource::JobCount - limit the job count (-j)

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
