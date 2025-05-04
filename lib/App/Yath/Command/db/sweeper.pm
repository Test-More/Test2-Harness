package App::Yath::Command::db::sweeper;
use strict;
use warnings;

our $VERSION = '2.000007';

use App::Yath::Schema::Sweeper;

use App::Yath::Schema::Util qw/schema_config_from_settings/;

sub summary     { "Sweep a database" }
sub description { "Deletes old data from a database" }
sub group       { "database" }

use parent 'App::Yath::Command';
use Getopt::Yath;

include_options(
    'App::Yath::Options::DB',
);

option_group {group => 'sweeper', category => "Sweeper Options"} => sub {
    option coverage => (
        type => 'Bool',
        default => 1,
        description => 'Delete old coverage data (default: yes)',
    );

    option events => (
        type => 'Bool',
        default => 1,
        description => 'Delete old event data (default: yes)',
    );

    option job_try_fields => (
        type => 'Bool',
        default => 1,
        description => 'Delete old job field data (default: yes)',
    );

    option jobs => (
        type => 'Bool',
        default => 1,
        description => 'Delete old job data (default: yes)',
    );

    option job_tries => (
        type => 'Bool',
        default => 1,
        description => 'Delete old job try data (default: yes)',
    );

    option reports => (
        type => 'Bool',
        default => 1,
        description => 'Delete old report data (default: yes)',
    );

    option resources => (
        type => 'Bool',
        default => 1,
        description => 'Delete old resource data (default: yes)',
    );

    option run_fields => (
        type => 'Bool',
        default => 1,
        description => 'Delete old run_field data (default: yes)',
    );

    option runs => (
        type => 'Bool',
        default => 1,
        description => 'Delete old run data (default: yes)',
    );

    option subtests => (
        type => 'Bool',
        default => 1,
        description => 'Delete old subtest data (default: yes)',
    );

    option interval => (
        type => 'Scalar',
        default => "7 days",
        description => "Interval (sql format) to delete (things older than this) defeult: '7 days'",
    );

    option job_concurrency => (
        type => 'Scalar',
        default => 1,
        from_env_vars => ['YATH_SWEEPER_JOB_CONCURRENCY'],
        description => "How many jobs to process concurrently (This compounds with run concurrency)",
    );

    option run_concurrency => (
        type => 'Scalar',
        default => 1,
        from_env_vars => ['YATH_SWEEPER_RUN_CONCURRENCY'],
        description => "How many runs to process concurrently (This compounds with job concurrency)",
    );

    option name => (
        type => 'Scalar',
        default => sub { $ENV{USER} },
        from_env_vars => ['YATH_SWEEPER_NAME'],
        description => "Give a name to the sweep",
    );
};

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $config = schema_config_from_settings($settings);

    my $sweeper = App::Yath::Schema::Sweeper->new(
        interval => $settings->sweeper->interval,
        config   => $config,
    );

    $sweeper->sweep($settings->sweeper->all);

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
