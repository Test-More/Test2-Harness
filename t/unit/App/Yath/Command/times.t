use Test2::V0 -target => 'App::Yath::Command::times';

use File::Temp qw/tempdir/;
use Test2::Harness::Util::File::JSONL;
use Getopt::Yath::Settings;

my $dir = tempdir(CLEANUP => 1);

sub make_log {
    my (@events) = @_;
    my $file = "$dir/test_$$.jsonl";
    my $log = Test2::Harness::Util::File::JSONL->new(name => $file);
    $log->write(@events);
    return $file;
}

subtest 'run() displays timing data from log' => sub {
    my $logfile = make_log(
        {
            stamp      => 1,
            job_id     => 'job1',
            facet_data => {
                harness_job_end => {
                    rel_file => 't/fast.t',
                    times    => {
                        totals => { total => 1.5, startup => 0.3, events => 1.0, cleanup => 0.2 },
                    },
                },
            },
        },
        {
            stamp      => 2,
            job_id     => 'job2',
            facet_data => {
                harness_job_end => {
                    rel_file => 't/slow.t',
                    times    => {
                        totals => { total => 10.2, startup => 1.0, events => 8.0, cleanup => 1.2 },
                    },
                },
            },
        },
    );

    my $obj = CLASS->new(
        settings => Getopt::Yath::Settings->new({}),
        args     => [$logfile],
    );

    my $ret;
    my $stdout = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$stdout) or die $!;
        $ret = $obj->run();
    }

    is($ret, 0, 'run() returns 0');
    like($stdout, qr/fast\.t/, 'output includes fast.t');
    like($stdout, qr/slow\.t/, 'output includes slow.t');
    like($stdout, qr/TOTAL/i, 'output includes totals row');
};

subtest 'run() sorts by total (default) shortest first' => sub {
    my $logfile = make_log(
        {
            stamp      => 1,
            job_id     => 'job1',
            facet_data => {
                harness_job_end => {
                    rel_file => 't/slow.t',
                    times    => {
                        totals => { total => 10.0, startup => 5.0, events => 4.0, cleanup => 1.0 },
                    },
                },
            },
        },
        {
            stamp      => 2,
            job_id     => 'job2',
            facet_data => {
                harness_job_end => {
                    rel_file => 't/fast.t',
                    times    => {
                        totals => { total => 2.0, startup => 1.0, events => 0.5, cleanup => 0.5 },
                    },
                },
            },
        },
    );

    my $obj = CLASS->new(
        settings => Getopt::Yath::Settings->new({}),
        args     => [$logfile],
    );

    my $ret;
    my $stdout = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$stdout) or die $!;
        $ret = $obj->run();
    }

    is($ret, 0, 'run() returns 0');
    # Default sort by total puts fast.t before slow.t
    my $pos_fast = index($stdout, 'fast.t');
    my $pos_slow = index($stdout, 'slow.t');
    ok($pos_fast < $pos_slow, 'fast.t appears before slow.t (sorted by total ascending)');
};

subtest 'run() dies without a log file argument' => sub {
    my $obj = CLASS->new(
        settings => Getopt::Yath::Settings->new({}),
        args     => [],
    );

    like(
        dies { $obj->run() },
        qr/must specify a log file/i,
        'dies with helpful message when no log file given',
    );
};

subtest 'run() dies for invalid field' => sub {
    my $logfile = make_log(
        {
            stamp      => 1,
            job_id     => 'job1',
            facet_data => {
                harness_job_end => {
                    rel_file => 't/a.t',
                    times    => { totals => { total => 1.0, startup => 0.5, events => 0.3, cleanup => 0.2 } },
                },
            },
        },
    );

    my $obj = CLASS->new(
        settings => Getopt::Yath::Settings->new({}),
        args     => [$logfile, 'bogus_field'],
    );

    like(
        dies { $obj->run() },
        qr/not a valid field/,
        'dies for unknown sort field',
    );
};

done_testing;
