package App::Yath::Options::Resource;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/mod2file fqmod/;

use Getopt::Yath;

option_group {group => 'resource', category => "Resource Options"} => sub {
    option classes => (
        type  => 'Map',
        name  => 'resources',
        field => 'classes',
        alt   => ['resource'],

        description => 'Specify resources. Use "+" to give a fully qualified module name. Without "+" "App::Yath::Resource::" and "Test2::Harness::Resource::" will be searched for a matching resource module.',

        long_examples  => [' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],
        short_examples => ['MyResource',     ' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],

        normalize => sub { fqmod($_[0], ['App::Yath::Resource', 'Test2::Harness::Resource']), ref($_[1]) ? $_[1] : [split(',', $_[1] // '')] },

        mod_adds_options => 1,
    );

    option shared_jobs_config => (
        type          => 'Scalar',
        default       => '.sharedjobslots.yml',
        long_examples => [' .sharedjobslots.yml', ' relative/path/.sharedjobslots.yml', ' /absolute/path/.sharedjobslots.yml'],
        description   => 'Where to look for a shared slot config file. If a filename with no path is provided yath will search the current and all parent directories for the name.',
    );

    option slots => (
        type           => 'Scalar',
        short          => 'j',
        default        => 1,
        alt            => ['jobs', 'job_count'],
        description    => 'Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.',
        long_examples  => [' 4', ' 8:2'],
        short_examples => ['4',  '8:2'],
        from_env_vars  => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],
        clear_env_vars => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],

        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            if ($params{action} eq 'set' || $params{action} eq 'initialize') {
                my ($val) = @{$params{val}};
                return unless $val =~ m/:/;
                my ($jobs, $slots) = split /:/, $val;
                @{$params{val}} = ($jobs);
                $params{group}->{job_slots} = $slots;
            }
        },
    );

    option job_slots => (
        type  => 'Scalar',
        alt   => ['slots_per_job'],
        short => 'x',

        description    => "This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.",
        from_env_vars  => ['T2_HARNESS_JOB_CONCURRENCY'],
        clear_env_vars => ['T2_HARNESS_JOB_CONCURRENCY'],
        long_examples  => [' 2'],
        short_examples => ['2'],

        default => sub {
            my ($opt, $settings) = @_;
            $settings->resource->slots // 1;
        },
    );

    option_post_process \&jobs_post_process;
};

sub jobs_post_process {
    my ($options, $state) = @_;

    my $settings = $state->{settings};
    my $resource = $settings->resource;
    $resource->field(slots     => 1) unless $resource->slots;
    $resource->field(job_slots => 1) unless $resource->job_slots;

    my $slots     = $resource->slots;
    my $job_slots = $resource->job_slots;

    my @args = (
        slots     => $slots,
        job_slots => $job_slots,
    );

    die "The slots per job (set to $job_slots) must not be larger than the total number of slots (set to $slots).\n" if $job_slots > $slots;

    my %found;
    for my $r (keys %{$resource->classes}) {
        require(mod2file($r));
        next unless $r->is_job_limiter;
        $found{$r}++;
    }

    warn "Fix shared slots";

    if (keys %found) {
        unshift @{$resource->classes->{$_} //= []} => @args;
    }
    else {
        require Test2::Harness::Resource::JobCount;
        $resource->classes->{'Test2::Harness::Resource::JobCount'} = [@args];
    }
}

1;

__END__
sub jobs_post_process {
    my ($settings) = @_;

    my $resource = $settings->resource;

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

1;
