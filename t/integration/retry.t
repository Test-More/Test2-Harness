use Test2::V0;
use App::Yath::Tester qw/yath_test_with_log yath_start yath_stop yath_run_with_log/;
use Test2::Harness::Util::File::JSONL;

use File::Temp qw/tempdir/;


for my $tool (qw/yath_test_with_log yath_run_with_log/) {
    subtest $tool => sub {
        my $cmd = __PACKAGE__->can($tool);

        my $dir = tempdir(CLEANUP => 1);
        $ENV{RETRY_DIR} = $dir;

        ok(!yath_start('-q'), "Started yath") if $tool eq 'yath_run_with_log';

        my ($exit, $log) = $cmd->('retry', '-r3', '-qqq');
        ok(!$exit, "Passed");
        my $final = ($log->poll())[-2];
        is($final->{facet_data}->{harness_final}->{pass}, T(), "Passed in log");

        open(my $fh, '>', File::Spec->catfile($dir, 'fail_once')) or die "$!";
        print $fh "1\n";
        close($fh);

        ($exit, $log) = $cmd->('retry', '-r3', '-qqq');
        ok(!$exit, "Passed");
        $final = ($log->poll())[-2];
        my $retry_data = $final->{facet_data}->{harness_final}->{retried}->[0];
        my ($uuid, $tries, $file, $status) = @$retry_data;
        is($tries, 2, "Tried twice");
        like($file, qr{retry\.tx}, "Retried the right file");
        is($status, 'YES', "Eventually passed");

        open($fh, '>', File::Spec->catfile($dir, 'fail_repeatedly')) or die "$!";
        print $fh "1\n";
        close($fh);

        ($exit, $log) = $cmd->('retry', '-r3', '-qqq');
        ok($exit, "Did not pass");
        $final      = ($log->poll())[-2];
        $retry_data = $final->{facet_data}->{harness_final}->{retried}->[0];
        ($uuid, $tries, $file, $status) = @$retry_data;
        is($tries, 3, "Tried 3 times");
        like($file, qr{retry\.tx}, "Retried the right file");
        is($status, 'NO', "Never passed");

        ok(!yath_stop('-qqq'), "Stopped yath") if $tool eq 'yath_run_with_log';
    };
}


done_testing;
