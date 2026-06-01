use Test2::V0;
use v5.38;

use File::Temp qw/tempfile/;
use File::Spec ();

use App::Yath2::TestFile;

# App::Yath2::TestFile is the producer: it scans a file (shebang + HARNESS2:
# directives) and builds a final Test2::Harness2::Run::Job.

sub write_test ($body) {
    my ($fh, $path) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print {$fh} $body;
    close($fh);
    return $path;
}

subtest paths => sub {
    my $path = write_test("use strict;\n1;\n");
    my $tf   = App::Yath2::TestFile->new(file => $path);
    is($tf->absolute, File::Spec->rel2abs($path), "absolute derived");
    is($tf->relative, File::Spec->abs2rel($path), "relative derived");
};

subtest missing_file => sub {
    like(
        dies { App::Yath2::TestFile->new(file => '/no/such/file/here.t') },
        qr/Invalid test file/,
        "missing file rejected",
    );
};

subtest scan_directives => sub {
    my $path = write_test(<<'EOT');
#!/usr/bin/perl -w
# HARNESS2: category isolation
# HARNESS2: duration short
# HARNESS2: conflicts db net
# HARNESS2: feature.fork @off
# HARNESS2: timeout.event 42
# HARNESS2: meta.note "hi there"
use strict;
print "ok\n";
EOT

    my $tf = App::Yath2::TestFile->new(file => $path);
    $tf->scan;

    is($tf->category, 'isolation', "category directive");
    is($tf->duration, 'short', "duration directive");
    is([sort @{$tf->conflicts}], ['db', 'net'], "conflicts directive");
    is($tf->switches, ['-w'], "switches from shebang");
    is($tf->features->{fork}, 0, "feature.fork off");
    is($tf->event_timeout, 42, "timeout.event directive");
    is($tf->meta->{note}, ['hi there'], "meta directive");
};

subtest scan_is_idempotent => sub {
    my $path = write_test("# HARNESS2: duration long\n1;\n");
    my $tf   = App::Yath2::TestFile->new(file => $path);
    $tf->scan;
    $tf->scan;    # second call must not double-apply or die
    is($tf->duration, 'long', "duration still correct after re-scan");
};

subtest build_job => sub {
    my $path = write_test(<<'EOT');
# HARNESS2: category general
# HARNESS2: conflicts db
1;
EOT

    my $tf  = App::Yath2::TestFile->new(file => $path);
    my $job = $tf->build_job(run_uuid => 'R', run_ord => 1, job_uuid => 'J', job_ord => 3);

    isa_ok($job, ['Test2::Harness2::Run::Job'], "produced a Run::Job");
    is($job->run_uuid, 'R', "carried run_uuid");
    is($job->job_uuid, 'J', "carried job_uuid");
    is($job->job_ord, 3, "carried job_ord");
    is($job->category, 'general', "carried scanned category");
    is([$job->conflicts_list], ['db'], "carried scanned conflicts");
    is($job->absolute, File::Spec->rel2abs($path), "carried absolute path");

    # The serialized form round-trips the scan data the harness will rehydrate.
    my $data = $job->TO_JSON;
    is($data->{category}, 'general', "TO_JSON carries category");
    is($data->{conflicts}, ['db'], "TO_JSON carries conflicts");
};

subtest malformed_feature_warns => sub {
    my $path = write_test("# HARNESS2: feature fork\n1;\n");
    my $tf   = App::Yath2::TestFile->new(file => $path);
    my $warning;
    local $SIG{__WARN__} = sub { $warning .= $_[0] };
    ok(lives { $tf->scan }, "a flat 'feature' directive does not crash the scan");
    like($warning, qr/malformed 'feature' directive/, "it warns instead");
};

done_testing;
