package Test2::Harness2::Test::Loggers;
use strict;
use warnings;

our $VERSION = '2.000011';

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    classic_harness_loggers
    classic_test_loggers
    classic_logger_specs
};

# Return the pair of logger specs the harness used to auto-create for
# its own interpose collector. Pass these as the harness's `loggers`
# arg to keep the on-disk layout under
# $workdir/logs/services/$name/{events.jsonl,state.json}.
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
            output_file => "$workdir/logs/services/$name/events.jsonl",
        ],
    );
    push @out => [
        'Test2::Harness2::Collector::Logger::JSON',
        output_file => "$workdir/logs/services/$name/state.json",
        spec        => $spec,
    ] if defined $spec;

    return \@out;
}

# Per-test-job logger specs. output_file is omitted on purpose: the
# logger role derives the path from the collector's identity attrs
# (logdir / run_id / job_id / job_try), which is how every per-job
# collector wires up after the logger-paths refactor.
sub classic_test_loggers {
    return [
        'Test2::Harness2::Collector::Logger::JSONL',
        'Test2::Harness2::Collector::Logger::JSON',
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
