use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness::Util::JSON qw/encode_json/;

require App::Yath::Command::times;

subtest 'jobs without timing data do not crash' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $logfile = "$dir/test.jsonl";

    # Create a minimal log with one job that has times and one without
    open my $fh, '>', $logfile or die "Cannot write $logfile: $!";

    # Job with complete timing data
    print $fh encode_json({
        stamp      => 1000000,
        job_id     => 'job-1',
        facet_data => {
            harness_job_end => {
                rel_file => 't/good.t',
                times    => {
                    totals => {
                        total   => 1.5,
                        startup => 0.5,
                        events  => 0.8,
                        cleanup => 0.2,
                    },
                },
            },
        },
    }), "\n";

    # Job WITHOUT timing data (times key missing from harness_job_end)
    print $fh encode_json({
        stamp      => 1000001,
        job_id     => 'job-2',
        facet_data => {
            harness_job_end => {
                rel_file => 't/no_times.t',
                # no 'times' key here
            },
        },
    }), "\n";

    close $fh;

    my $cmd = bless {
        args => [$logfile],
    }, 'App::Yath::Command::times';

    my $out = '';
    my $exit;
    ok(
        lives {
            local *STDOUT;
            open STDOUT, '>', \$out or die;
            $exit = $cmd->run();
        },
        'yath times does not crash on jobs missing timing data'
    ) or diag $@;

    is($exit, 0, 'exit code is 0');
    like($out, qr/good\.t/, 'output includes the job with timing data');
};

done_testing;
