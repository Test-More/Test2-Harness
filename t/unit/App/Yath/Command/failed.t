use Test2::V0 -target => 'App::Yath::Command::failed';

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

sub make_settings {
    my (%opts) = @_;
    return Getopt::Yath::Settings->new({
        failed => { brief => $opts{brief} // 0 },
    });
}

subtest 'run() with no failures' => sub {
    my $logfile = make_log(
        {
            stamp      => 1,
            job_id     => 'job1',
            facet_data => {
                harness_job_end => { rel_file => 't/pass.t', fail => 0 },
            },
        },
    );

    my $obj = CLASS->new(
        settings => make_settings(),
        args     => [$logfile],
    );

    my $ret;
    my $out = intercept { $ret = $obj->run() };
    is($ret, 0, 'run() returns 0');
};

subtest 'run() detects failed tests' => sub {
    my $logfile = make_log(
        {
            stamp      => 1,
            job_id     => 'job1',
            facet_data => {
                harness_job_end => { rel_file => 't/fail.t', fail => 1 },
            },
        },
        {
            stamp      => 2,
            job_id     => 'job2',
            facet_data => {
                harness_job_end => { rel_file => 't/pass.t', fail => 0 },
            },
        },
    );

    my $obj = CLASS->new(
        settings => make_settings(),
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
    like($stdout, qr/fail\.t/, 'output includes the failed test file');
    unlike($stdout, qr/pass\.t/, 'output does not include the passing test file');
};

subtest 'run() brief mode prints only failed filenames' => sub {
    my $logfile = make_log(
        {
            stamp      => 1,
            job_id     => 'job1',
            facet_data => {
                harness_job_end => { rel_file => 't/fail.t', fail => 1 },
            },
        },
    );

    my $obj = CLASS->new(
        settings => make_settings(brief => 1),
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
    like($stdout, qr{t/fail\.t}, 'brief mode prints the failed filename');
};

subtest 'run() dies without a log file argument' => sub {
    my $obj = CLASS->new(
        settings => make_settings(),
        args     => [],
    );

    like(
        dies { $obj->run() },
        qr/must specify a log file/i,
        'dies with helpful message when no log file given',
    );
};

subtest 'run() dies for invalid log file' => sub {
    my $obj = CLASS->new(
        settings => make_settings(),
        args     => ['/nonexistent/file.jsonl'],
    );

    like(
        dies { $obj->run() },
        qr/not a valid log file/,
        'dies for nonexistent log file',
    );
};

done_testing;
