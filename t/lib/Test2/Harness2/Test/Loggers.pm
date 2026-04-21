package Test2::Harness2::Test::Loggers;
use strict;
use warnings;

our $VERSION = '2.000011';

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    classic_harness_loggers
    classic_run_service_loggers
    classic_test_loggers
    classic_logger_specs
};

# Return the pair of logger specs the harness used to auto-create for
# its own interpose collector. Pass these as the harness's `loggers`
# arg to keep the classic on-disk layout under
# $workdir/logs/services/$name.{jsonl,json}.
#
# The Logger::JSON entry requires a $spec object (anything that can
# TO_JSON); only the JSONL is included when no $spec is supplied.
# Callers that want the .json snapshot pass their harness instance
# (or any other TO_JSON-capable object) as the third argument.
sub classic_harness_loggers {
    my ($workdir, $name, $spec) = @_;
    $name //= 'harness';

    my @out = (
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => "$workdir/logs/services/$name.jsonl",
        ],
    );
    push @out => [
        'Test2::Harness2::Collector::Logger::JSON',
        output_file => "$workdir/logs/services/$name.json",
        spec        => $spec,
    ] if defined $spec;

    return \@out;
}

# Per-run service logger specs. Uses the RunService's %LOGDIR%,
# %RUN_ID%, %LOG_NAME% semantics -- but since LOG_NAME isn't part of
# the RunService placeholder set (yet), callers typically know the
# run_id up-front and just hardcode the path.
sub classic_run_service_loggers {
    my ($workdir, $run_id, $log_name) = @_;
    $log_name //= 'run';
    return [
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => "$workdir/logs/runs/$run_id/services/$log_name.jsonl",
        ],
    ];
}

# Per-test-job logger specs. These use RunService placeholders so the
# same list can be reused across every job the run launches.
# Logger::JSON's 'spec' attr is optional; omitting it here means the
# 0.json starts empty and is overwritten with exit / pass data at
# shutdown -- enough for the Command::test tally (which only looks
# at 'pass').
sub classic_test_loggers {
    return [
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => '%LOG_DIR%/%JOB_TRY%.jsonl',
        ],
        [
            'Test2::Harness2::Collector::Logger::JSON',
            output_file => '%LOG_DIR%/%JOB_TRY%.json',
        ],
    ];
}

# Convenience: everything a legacy-style harness construction needs.
# Returns a (%args) list ready to merge into spawn() / new().
sub classic_logger_specs {
    my ($workdir, $harness_name) = @_;
    return (
        loggers      => classic_harness_loggers($workdir, $harness_name),
        test_loggers => classic_test_loggers(),
    );
}

1;
