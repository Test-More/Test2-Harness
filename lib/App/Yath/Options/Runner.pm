package App::Yath::Options::Runner;
use strict;
use warnings;

our $VERSION = '1.000142';

use List::Util qw/min/;
use Test2::Util qw/IS_WIN32/;
use App::Yath::Util qw/find_in_updir/;
use Test2::Harness::Util qw/clean_path mod2file/;
use Test2::Harness::Util::UUID qw/gen_uuid/;
use File::Spec;

use App::Yath::Options;

my $DEFAULT_COVER_ARGS = '-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';

option_group {prefix => 'runner', category => "Runner Options"} => sub {
    option use_fork => (
        alt         => ['fork'],
        description => "(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' comment in their header to disable forking only for those tests.",
        env_vars => [qw/!T2_NO_FORK T2_HARNESS_FORK !T2_HARNESS_NO_FORK YATH_FORK !YATH_NO_FORK/],
        default     => sub {
            return 0 if IS_WIN32;
            return 1;
        },
    );

    option abort_on_bail => (
        type => 'b',
        default => 1,
        description => "Abort all testing if a bail-out is encountered (default: on)",
    );

    option use_timeout => (
        alt         => ['timeout'],
        description => "(default: on) Enable/disable timeouts",
        default     => 1,
    );

    option shared_jobs_config => (
        type => 's',
        description => 'Where to look for a shared slot config file. If a filename with no path is provided yath will search the current and all parent directories for the name.',
        default => '.sharedjobslots.yml',
        long_examples => [ ' .sharedjobslots.yml', ' relative/path/.sharedjobslots.yml', ' /absolute/path/.sharedjobslots.yml' ],
    );

    post \&jobs_post_process;
    option job_count => (
        type           => 's',
        short          => 'j',
        alt            => ['jobs'],
        description    => 'Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.',
        env_vars       => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],
        clear_env_vars => 1,
        long_examples  => [' 4', ' 8:2'],
        short_examples => ['4', '8:2'],

        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;

            my ($jobs, $slots) = split /:/, $norm;

            $$slot = $jobs;

            $settings->runner->slots_per_job($slots) if defined $slots;

            fix_job_resources($settings);
        },
    );

    option slots_per_job => (
        type => 's',
        short => 'x',
        description => "This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.",
        env_vars => ['T2_HARNESS_JOB_CONCURRENCY'],
        clear_env_vars => 1,
        long_examples => [' 2'],
        short_examples => ['2'],
    );

    option dump_depmap => (
        type => 'b',
        description => "When using staged preload, dump the depmap for each stage as json files",
        default => 0,
    );

    option includes => (
        name        => 'include',
        short       => 'I',
        type        => 'm',
        description => "Add a directory to your include paths",
    );

    option resources => (
        name => 'resource',
        short => 'R',
        type => 'm',
        description => "Use a resource module to assign resource assignments to individual tests",
        long_examples  => [' Port', ' +Test2::Harness::Runner::Resource::Port'],
        short_examples => [' Port'],

        normalize => sub {
            my $val = shift;

            $val = "Test2::Harness::Runner::Resource::$val"
            unless $val =~ s/^\+//;

            return $val;
        },
    );

    option tlib => (
        description => "(Default: off) Include 't/lib' in your module path",
        default     => 0,
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;
            push @{$settings->runner->includes} => File::Spec->catdir('t', 'lib');
        },
    );

    option lib => (
        short => 'l',
        description => "(Default: include if it exists) Include 'lib' in your module path",
        default     => 1,
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;
            push @{$settings->runner->includes} => 'lib';
            $settings->runner->lib(0);
            $settings->runner->blib(0);
        },
    );

    option blib => (
        short => 'b',
        description => "(Default: include if it exists) Include 'blib/lib' and 'blib/arch' in your module path",
        default     => 1,
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;

            push @{$settings->runner->includes} => (
                File::Spec->catdir('blib', 'lib'),
                File::Spec->catdir('blib', 'arch'),
            );

            $settings->runner->lib(0);
            $settings->runner->blib(0);
        },
    );

    option unsafe_inc => (
        description => "perl is removing '.' from \@INC as a security concern. This option keeps things from breaking for now.",
        env_vars    => [qw/PERL_USE_UNSAFE_INC/],
        default     => 0,
    );

    option preloads => (
        type        => 'm',
        alt         => ['preload'],
        short       => 'P',
        description => 'Preload a module before running tests',
    );

    option preload_threshold => (
        short => 'W',
        alt => ['Pt'],
        type => 's',
        default => 0,
        description => "Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. This has no effect for a persistent runner. The default is 0, and it means always preload."
    );

    option nytprof => (
        type => 'b',
        description => "Use Devel::NYTProf on tests. This will set addpid=1 for you. This works with or without fork.",
        long_examples => [''],
    );

    post \&cover_post_process;
    option cover => (
        type        => 'd',
        description => "Use Devel::Cover to calculate test coverage. This disables forking. If no args are specified the following are used: $DEFAULT_COVER_ARGS",
        long_examples => ['', '=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl'],
        action      => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

            return $$slot = $DEFAULT_COVER_ARGS if $norm eq '1';
            return $$slot = $norm;
        },
    );

    option switch => (
        field        => 'switches',
        short        => 'S',
        type         => 'm',
        description  => 'Pass the specified switch to perl for each test. This is not compatible with preload.',
    );

    option event_timeout => (
        alt => ['et'],

        type => 's',
        default => 60,

        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Kill test if no output is received within timeout period. (Default: 60 seconds). Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis. This prevents a hung test from running forever.',
    );

    option post_exit_timeout => (
        alt => ['pet'],

        type => 's',
        default => 15,

        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Stop waiting post-exit after the timeout period. (Default: 15 seconds) Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness detects an incomplete plan after the test exits it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.'
    );

    option runner_id => (
        type => 's',
        default => sub { gen_uuid() },
        description => 'Runner ID (usually a generated uuid)',
    );
};

sub jobs_post_process {
    my %params   = @_;
    my $settings = $params{settings};

    my $runner = $settings->runner or return;

    fix_job_resources($settings);

    $ENV{T2_HARNESS_MY_JOB_COUNT}           = $runner->job_count;
    $ENV{T2_HARNESS_MY_MAX_JOB_CONCURRENCY} = $runner->slots_per_job;
}

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

sub cover_post_process {
    my %params   = @_;
    my $settings = $params{settings};

    if ($ENV{T2_DEVEL_COVER} && !$settings->runner->cover) {
        $settings->runner->field(cover => $ENV{T2_DEVEL_COVER} eq '1' ? $ENV{T2_DEVEL_COVER} : $DEFAULT_COVER_ARGS);
    }

    return unless $settings->runner->cover;

    # For nested things
    $ENV{T2_NO_FORK} = 1;
    $ENV{T2_DEVEL_COVER} = $settings->runner->cover;
    $settings->runner->field(use_fork => 0);

    return unless $settings->check_prefix('run');
    push @{$settings->run->load_import->{'@'}} => 'Devel::Cover';
    $settings->run->load_import->{'Devel::Cover'} = [split(/,/, $settings->runner->cover)];
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Runner - Runner options for Yath.

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
