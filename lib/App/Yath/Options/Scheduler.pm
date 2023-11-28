package App::Yath::Options::Scheduler;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;
include_options(
    'App::Yath::Options::Tests',
);

option_group {group => 'scheduler', category => 'Scheduler Options'} => sub {
    option class => (
        name    => 'scheduler',
        field   => 'class',
        type    => 'Scalar',
        default => 'Test2::Harness::Scheduler::Default',

        mod_adds_options => 1,
        long_examples    => [' MyScheduler', ' +Test2::Harness::MyScheduler'],
        description      => 'Specify what Scheduler subclass to use. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness::Scheduler::XXX namespace is assumed.',

        normalize => sub { fqmod('Test2::Harness::Scheduler', $_[0]) },
    );

    option shared_jobs_config => (
        type          => 'Scalar',
        default       => '.sharedjobslots.yml',
        long_examples => [' .sharedjobslots.yml', ' relative/path/.sharedjobslots.yml', ' /absolute/path/.sharedjobslots.yml'],
        description   => 'Where to look for a shared slot config file. If a filename with no path is provided yath will search the current and all parent directories for the name.',
    );
};

option_post_process \&scheduler_post_process;

sub scheduler_post_process {
    my ($options, $state) = @_;

    my $settings  = $state->{settings};
    my $scheduler = $settings->scheduler;
    my $tests     = $settings->tests;

    warn "Fix shared job slots";
}

1;

warn "Do we need the stuff under __END__?";

__END__

sub fix_job_resources {
    my ($settings) = @_;

    my $runner = $settings->runner;

    require Test2::Harness::Runner::Resource::SharedJobSlots::Config;
    my $sconf = Test2::Harness::Runner::Resource::SharedJobSlots::Config->find(settings => $settings);

    my %found;
    for my $r (@{$runner->resources}) {
        require(mod2file($r));
        next unless $r->job_limiter;
        $found{$r}++;
    }

    if ($sconf && !$found{'Test2::Harness::Runner::Resource::SharedJobSlots'}) {
        if (delete $found{'Test2::Harness::Runner::Resource::JobCount'}) {
            @{$settings->runner->resources} = grep { $_ ne 'Test2::Harness::Runner::Resource::JobCount' } @{$runner->resources};
        }

        if (!keys %found) {
            require Test2::Harness::Runner::Resource::SharedJobSlots;
            unshift @{$runner->resources} => 'Test2::Harness::Runner::Resource::SharedJobSlots';
            $found{'Test2::Harness::Runner::Resource::SharedJobSlots'}++;
        }
    }
    elsif (!keys %found) {
        require Test2::Harness::Runner::Resource::JobCount;
        unshift @{$runner->resources} => 'Test2::Harness::Runner::Resource::JobCount';
    }

    if ($found{'Test2::Harness::Runner::Resource::SharedJobSlots'} && $sconf) {
        $runner->field(job_count     => $sconf->default_slots_per_run || $sconf->max_slots_per_run) if $runner && !$runner->job_count;
        $runner->field(slots_per_job => $sconf->default_slots_per_job || $sconf->max_slots_per_job) if $runner && !$runner->slots_per_job;

        my $run_slots = $runner->job_count;
        my $job_slots = $runner->slots_per_job;

        die "Requested job count ($run_slots) exceeds the system shared limit (" . $sconf->max_slots_per_run . ").\n"
            if $run_slots > $sconf->max_slots_per_run;

        die "Requested job concurrency ($job_slots) exceeds the system shared limit (" . $sconf->max_slots_per_job . ").\n"
            if $job_slots > $sconf->max_slots_per_job;
    }

    $runner->field(job_count     => 1) if $runner && !$runner->job_count;
    $runner->field(slots_per_job => 1) if $runner && !$runner->slots_per_job;

    my $run_slots = $runner->job_count;
    my $job_slots = $runner->slots_per_job;

    die "The slots_per_job (set to $job_slots) must not be larger than the job_count (set to $run_slots).\n" if $job_slots > $run_slots;
}



=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Scheduler - Scheduler options for Yath.

=head1 DESCRIPTION

This is where command line options for the runner are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
