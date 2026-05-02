use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::TestFile;

my $tdir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} $content;
    close($fh);
    return $path;
}

sub tf_for {
    my ($name, @directives) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    my $body = "#!/usr/bin/perl\n" . join("\n", @directives) . "\nuse strict;\n";
    write_file($path, $body);
    return App::Yath2::TestFile->new(file => $path);
}

subtest 'HARNESS-SMOKE sets features->{smoke} = 1' => sub {
    my $tf = tf_for('smoke.t', '# HARNESS-SMOKE');
    $tf->scan;
    is($tf->feature('smoke'), 1, 'smoke feature flagged on');
};

subtest 'bare HARNESS-RETRY defaults retry to 1' => sub {
    my $tf = tf_for('retry_bare.t', '# HARNESS-RETRY');
    $tf->scan;
    is($tf->retry,          1, 'retry defaults to 1');
    is($tf->retry_isolated, 0, 'retry_isolated stays 0');
};

subtest 'HARNESS-RETRY 3 sets retry count to 3' => sub {
    my $tf = tf_for('retry_3.t', '# HARNESS-RETRY 3');
    $tf->scan;
    is($tf->retry,          3, 'retry count honored');
    is($tf->retry_isolated, 0, 'retry_isolated stays 0');
};

subtest 'HARNESS-RETRY-ISO sets retry=1, retry_isolated=1' => sub {
    my $tf = tf_for('retry_iso.t', '# HARNESS-RETRY-ISO');
    $tf->scan;
    is($tf->retry,          1, 'retry defaults to 1 under ISO alone');
    is($tf->retry_isolated, 1, 'retry_isolated flagged on');
};

subtest 'HARNESS-RETRY 2 ISO preserves count and flags isolation' => sub {
    my $tf = tf_for('retry_2_iso.t', '# HARNESS-RETRY 2 ISO');
    $tf->scan;
    is($tf->retry,          2, 'explicit count wins');
    is($tf->retry_isolated, 1, 'retry_isolated flagged on');
};

subtest 'HARNESS-RETRY ISO 4 is order-insensitive' => sub {
    my $tf = tf_for('retry_iso_4.t', '# HARNESS-RETRY ISO 4');
    $tf->scan;
    is($tf->retry,          4, 'explicit count overrides ISO default');
    is($tf->retry_isolated, 1, 'retry_isolated flagged on');
};

subtest 'HARNESS-RETRY garbage warns but does not die' => sub {
    my $tf       = tf_for('retry_garbage.t', '# HARNESS-RETRY garbage');
    my $warnings = warnings { $tf->scan };
    is(scalar @$warnings, 1, 'one warning emitted');
    like(
        $warnings->[0],
        qr/Unknown 'HARNESS-RETRY' argument 'garbage'/,
        'warning text mentions the unknown argument',
    );
};

subtest 'HARNESS-NO-RETRY then HARNESS-RETRY 3 lets the count win' => sub {
    my $tf = tf_for('no_then_retry.t', '# HARNESS-NO-RETRY', '# HARNESS-RETRY 3');
    $tf->scan;
    is($tf->retry, 3, 'explicit count overrides the prior NO-RETRY = 0');
};

subtest 'Multiple HARNESS-RETRY counts: later value wins' => sub {
    my $tf = tf_for('retry_twice.t', '# HARNESS-RETRY 2', '# HARNESS-RETRY 5');
    $tf->scan;
    is($tf->retry, 5, 'the final explicit count wins');
};

done_testing;
