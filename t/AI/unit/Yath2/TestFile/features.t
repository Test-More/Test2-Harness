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
    my ($name, $directive) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    write_file($path, "#!/usr/bin/perl\n" . $directive . "\nuse strict;\n");
    return App::Yath2::TestFile->new(file => $path);
}

# Scanning must never trip the Stage D fall-through warn for any of
# the nine valid directives exercised below.
my @warns;
local $SIG{__WARN__} = sub { push @warns => $_[0] };

subtest 'HARNESS-NO-TIMEOUT sets features->{timeout} = 0' => sub {
    my $tf = tf_for('no_timeout.t', '# HARNESS-NO-TIMEOUT');
    $tf->scan;
    is($tf->feature('timeout'), 0, 'timeout feature flagged off');
};

subtest 'HARNESS-NO-FORK sets features->{fork} = 0' => sub {
    my $tf = tf_for('no_fork.t', '# HARNESS-NO-FORK');
    $tf->scan;
    is($tf->feature('fork'), 0, 'fork feature flagged off');
};

subtest 'HARNESS-NO-PRELOAD sets features->{preload} = 0' => sub {
    my $tf = tf_for('no_preload.t', '# HARNESS-NO-PRELOAD');
    $tf->scan;
    is($tf->feature('preload'), 0, 'preload feature flagged off');
};

subtest 'HARNESS-NO-STREAM sets features->{stream} = 0' => sub {
    my $tf = tf_for('no_stream.t', '# HARNESS-NO-STREAM');
    $tf->scan;
    is($tf->feature('stream'), 0, 'stream feature flagged off');
};

subtest 'HARNESS-NO-RUN sets features->{run} = 0' => sub {
    my $tf = tf_for('no_run.t', '# HARNESS-NO-RUN');
    $tf->scan;
    is($tf->feature('run'), 0, 'run feature flagged off');
};

subtest 'HARNESS-NO-IO-EVENTS collapses to features->{io_events} = 0' => sub {
    my $tf = tf_for('no_io_events.t', '# HARNESS-NO-IO-EVENTS');
    $tf->scan;
    is($tf->feature('io_events'), 0, 'IO-EVENTS collapses to io_events via lc(join _)');
};

subtest 'HARNESS-USE-ISOLATION sets features->{isolation} = 1' => sub {
    my $tf = tf_for('use_isolation.t', '# HARNESS-USE-ISOLATION');
    $tf->scan;
    is($tf->feature('isolation'), 1, 'isolation feature flagged on');
};

subtest 'HARNESS-YES-STREAM sets features->{stream} = 1' => sub {
    my $tf = tf_for('yes_stream.t', '# HARNESS-YES-STREAM');
    $tf->scan;
    is($tf->feature('stream'), 1, 'yes arm turns stream on');
};

subtest 'HARNESS-NO-RETRY is special-cased into retry, not features' => sub {
    my $tf = tf_for('no_retry.t', '# HARNESS-NO-RETRY');
    $tf->scan;
    is($tf->retry, 0, 'retry slot set to 0');
    ok(!exists $tf->features->{retry}, 'features hash did not receive a retry key');
};

is(\@warns, [], 'no unknown-directive warnings across any valid NO/YES/USE form');

done_testing;
