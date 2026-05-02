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

subtest 'HARNESS-DURATION-LONG sets duration = long' => sub {
    my $tf = tf_for('dur_long.t', '# HARNESS-DURATION-LONG');
    $tf->scan;
    is($tf->duration, 'long', 'duration lowercased to long');
    is($tf->category, undef,  'category untouched');
};

subtest 'HARNESS-DUR-SHORT (alias) sets duration = short' => sub {
    my $tf = tf_for('dur_short.t', '# HARNESS-DUR-SHORT');
    $tf->scan;
    is($tf->duration, 'short', 'dur alias accepted');
};

subtest 'HARNESS-DURATION MEDIUM (space form) sets duration = medium' => sub {
    my $tf = tf_for('dur_medium.t', '# HARNESS-DURATION MEDIUM');
    $tf->scan;
    is($tf->duration, 'medium', 'space-separated form accepted');
};

subtest 'HARNESS-CATEGORY-IO sets category = io' => sub {
    my $tf = tf_for('cat_io.t', '# HARNESS-CATEGORY-IO');
    $tf->scan;
    is($tf->category, 'io',  'category lowercased to io');
    is($tf->duration, undef, 'duration untouched');
};

subtest 'HARNESS-CAT-NETWORK (alias) sets category = network' => sub {
    my $tf = tf_for('cat_network.t', '# HARNESS-CAT-NETWORK');
    $tf->scan;
    is($tf->category, 'network', 'cat alias accepted');
};

subtest 'HARNESS-CATEGORY-LONG is sugar for HARNESS-DURATION-LONG' => sub {
    my $tf = tf_for('cat_as_dur.t', '# HARNESS-CATEGORY-LONG');
    $tf->scan;
    is($tf->duration, 'long', 'long/medium/short under CATEGORY routed to duration');
    is($tf->category, undef,  'category stays undef');
};

subtest 'HARNESS-STAGE-DBStage preserves case' => sub {
    my $tf = tf_for('stage.t', '# HARNESS-STAGE-DBStage');
    $tf->scan;
    is($tf->stage, 'DBStage', 'stage name case-preserved');
};

subtest 'no directive leaves category / duration / stage undef' => sub {
    my $tf = tf_for('plain.t');
    $tf->scan;
    is($tf->category, undef, 'category undef without directive');
    is($tf->duration, undef, 'duration undef without directive');
    is($tf->stage,    undef, 'stage undef without directive');
};

done_testing;
