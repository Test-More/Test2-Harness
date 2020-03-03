use Test2::V0;
# HARNESS-DURATION-LONG

use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

run_tests('test');

my $project = "asgadfgds";

unless ($ENV{AUTOMATED_TESTING}) {
    my $out = yath(
        command => 'start',
        pre     => ['--project', $project],
        args    => [],
        exit    => 0,
        test    => sub {
            run_tests('run');
            yath(command => 'stop', args => [], exit => 0);
        }
    );
}

sub run_tests {
    my ($cmd) = @_;

    yath(
        command => $cmd,
        pre => ['--project', $project],
        args    => [$dir, '--ext=tx', '-r3'],
        log     => 1,
        exit    => 0,
        test    => sub {
            my $out   = shift;
            my $final = ($out->{log}->poll())[-2];
            is($final->{facet_data}->{harness_final}->{pass}, T(), "Passed in log");
        },
    );

    yath(
        command => $cmd,
        pre     => ['--project', $project],
        args    => [$dir, '--ext=tx', '-r3', '--env-var' => "FAIL_ONCE=1", '-v'],
        log     => 1,
        exit    => 0,
        debug   => 0,
        test    => sub {
            my $out = shift;

            my $final      = ($out->{log}->poll())[-2];
            my $retry_data = $final->{facet_data}->{harness_final}->{retried}->[0];
            ok($retry_data, "got retry data") or return;
            my ($uuid, $tries, $file, $status) = @$retry_data;
            is($tries, 2, "Tried twice");
            like($file, qr{retry\.tx}, "Retried the right file");
            is($status, 'YES', "Eventually passed");
        },
    );

    yath(
        command => $cmd,
        pre => ['--project', $project],
        args    => [$dir, '--ext=tx', '-r3', '--env-var' => "FAIL_ALWAYS=1"],
        log     => 1,
        exit    => T(),
        test    => sub {
            my $out        = shift;
            my $final      = ($out->{log}->poll())[-2];
            my $retry_data = $final->{facet_data}->{harness_final}->{retried}->[0];
            my ($uuid, $tries, $file, $status) = @$retry_data;

            is($tries, 4, "Tried 4 times: 1 run + 3 retries");
            like($file, qr{retry\.tx}, "Retried the right file");
            is($status, 'NO', "Never passed");
        },
    );

    {
        note q[Retrying a symlink];

        my $sdir = $dir . '-symlinks';
        my $symlink = "$sdir/symlink.tl";

        unlink $symlink if -e $symlink;
        if ( eval{ symlink('retry.tx', $symlink) } ) {
            yath(
                command => 'test',
                args => [$sdir, '--ext=tl', '--retry' => 1, '--env-var' => "FAIL_ONCE=1", '-v' ],
                log  => 1,
                exit => 0,
                test => sub {
                    my $out = shift;

                    my $final      = ($out->{log}->poll())[-2];
                    my $retry_data = $final->{facet_data}->{harness_final}->{retried}->[0];
                    my ($uuid, $tries, $file, $status) = @$retry_data;

                    is $tries, 2, 'retried a broken symlink';
                    is $file, 't/integration/retry-symlinks/symlink.tl', "using symlink name";
                    is $status, 'YES', 'Succeded Eventually: YES';

                    unlike($out->{output}, qr{FAILED}, q[no failures]);
                },
            );
        }
    }

    {
        note q[Retrying a test failing due to a timeout];

        my $sdir = $dir . '-timeout';
        yath(
            command => 'test',
            args => [$sdir, '--ext=tx', '--retry' => 1, '--env-var' => "FAIL_ONCE=1", '-v' ],
            log  => 1,
            exit => 0,
            test => sub {
                my $out = shift;

                my $final      = ($out->{log}->poll())[-2];
                my $retry_data = $final->{facet_data}->{harness_final}->{retried}->[0];
                my ($uuid, $tries, $file, $status) = @$retry_data;

                #note $out->{output};

                is $tries, 2, 'retried a test when failing due to a timeout';
                is $file, 't/integration/retry-timeout/retry.tx', "retry.txt test";
                is $status, 'YES', 'Succeded Eventually: YES';

                unlike($out->{output}, qr{FAILED}, q[no failures]);
            },
        );
    }
};

done_testing;
