use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;

use App::Yath2::Log;
use App::Yath2::Concluder::Summary;

# Build a sealed log dir on disk: one run with a passing job, a failing
# job, and an abandoned (no-.sealed) job. The Summary concluder reads
# producer descriptors directly from the Log, so we exercise the real
# Directory backend rather than a mock.
sub _build_log {
    my %p   = @_;
    my $dir = tempdir(CLEANUP => 1);

    for my $r_id (@{$p{runs}}) {
        make_path("$dir/runs/$r_id");
        if ($p{seal_runs}{$r_id}) {
            open my $fh, '>', "$dir/runs/$r_id/.sealed" or die "seal run: $!";
            print $fh encode_json({
                sealed_at => 100, final_state => 'completed',
                pass      => $p{run_pass}{$r_id} // 1,
                exit      => $p{run_exit}{$r_id} // 0,
            });
            close $fh;
        }

        for my $j (@{$p{jobs}{$r_id} || []}) {
            my ($jid, $try, $sealed, $pass) = @$j;
            make_path("$dir/runs/$r_id/jobs/$jid/$try");
            open my $sp, '>', "$dir/runs/$r_id/jobs/$jid/$try/spec.jsonl" or die "spec: $!";
            close $sp;
            next unless $sealed;
            open my $fh, '>', "$dir/runs/$r_id/jobs/$jid/$try/.sealed" or die "seal job: $!";
            print $fh encode_json({
                sealed_at => 200, final_state => 'completed',
                pass      => $pass,
            });
            close $fh;
        }
    }

    return App::Yath2::Log->new(dir => $dir);
}

subtest 'no runs in log emits empty-summary line' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = App::Yath2::Log->new(dir => $dir);

    open my $fh, '>', \my $buf or die "scalar: $!";
    my $c = App::Yath2::Concluder::Summary->new(log => $log, out_fh => $fh);
    $c->run;
    close $fh;

    like($buf, qr/no runs in log/, 'empty-log message printed');
};

subtest 'tallies pass, fail, abandoned' => sub {
    my $log = _build_log(
        runs      => [1],
        seal_runs => {1 => 1},
        run_pass  => {1 => 0},    # mixed jobs, overall fail
        run_exit  => {1 => 1},
        jobs      => {
            1 => [
                ['j1', 0, 1, 1],        # sealed pass
                ['j2', 0, 1, 0],        # sealed fail
                ['j3', 0, 0, undef],    # abandoned (no .sealed)
            ],
        },
    );

    open my $fh, '>', \my $buf or die "scalar: $!";
    my $c = App::Yath2::Concluder::Summary->new(log => $log, out_fh => $fh);
    $c->run;
    close $fh;

    like($buf, qr/Run 1: 3 jobs, 1 passed, 1 failed, 1 abandoned/, 'counts');
    like($buf, qr/Failed jobs:/,                                   'failed-jobs header');
    like($buf, qr/j2/,                                             'failing job id listed');
    like($buf, qr/Result: FAILED \(exit=1\)/,                      'verdict + exit');
    like($buf, qr/={40,}/,                                         'banner rule present');
    unlike($buf, qr/j1/, 'passing job not in failed list');
};

subtest 'all-pass run' => sub {
    my $log = _build_log(
        runs      => [42],
        seal_runs => {42 => 1},
        run_pass  => {42 => 1},
        run_exit  => {42 => 0},
        jobs      => {
            42 => [
                ['a', 0, 1, 1],
                ['b', 0, 1, 1],
            ],
        },
    );

    open my $fh, '>', \my $buf or die "scalar: $!";
    my $c = App::Yath2::Concluder::Summary->new(log => $log, out_fh => $fh);
    $c->run;
    close $fh;

    like($buf, qr/Run 42: 2 jobs, 2 passed, 0 failed, 0 abandoned/, 'counts');
    like($buf, qr/Result: PASSED \(exit=0\)/,                       'verdict');
    unlike($buf, qr/Failed jobs:/, 'no failed-jobs section when all pass');
};

subtest 'unsealed run reports INCOMPLETE' => sub {
    my $log = _build_log(
        runs      => [7],
        seal_runs => {},    # run not sealed
        jobs      => {
            7 => [
                ['x', 0, 1, 1],
            ],
        },
    );

    open my $fh, '>', \my $buf or die "scalar: $!";
    my $c = App::Yath2::Concluder::Summary->new(log => $log, out_fh => $fh);
    $c->run;
    close $fh;

    like($buf, qr/Result: INCOMPLETE/, 'INCOMPLETE verdict on unsealed run');
    unlike($buf, qr/exit=/, 'no exit clause when run unsealed');
};

done_testing;
