use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::Finder;
use App::Yath2::TestFile;

# End-to-end verification that App::Yath2::Finder::exclude_file sees
# the per-file HARNESS metadata through the new TestFile parser. (Avoid
# writing the literal "HARNESS-<wildcard>" form in this comment because
# the scanner would treat it as a directive and warn.) exclude_file is a
# pure method that reads only its own HashBase flags plus the
# TestFile's check_feature / check_duration helpers, so we can exercise
# it with minimal Finder construction and a handful of fixture files.

my $tdir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} $content;
    close($fh);
    return $path;
}

sub tf {
    my ($name, $body) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    write_file($path, $body);
    return App::Yath2::TestFile->new(file => $path);
}

sub finder {
    return App::Yath2::Finder->new(
        search           => [$tdir],
        default_search   => [],
        exclude_files    => {},
        exclude_lists    => [],
        exclude_patterns => [],
        @_,
    );
}

my $noop = tf(
    'noop.t',
    "#!/usr/bin/perl\n# HARNESS-NO-RUN\nprint qq{should not run};\n",
);

my $long = tf(
    'long.t',
    "#!/usr/bin/perl\n# HARNESS-DURATION-LONG\nprint qq{long ok};\n",
);

my $short = tf(
    'short.t',
    "#!/usr/bin/perl\nprint qq{short ok};\n",
);

subtest 'HARNESS-NO-RUN excludes a file via check_feature(run => 1)' => sub {
    my $f = finder();
    is(
        [$f->exclude_file($noop)],
        ['File has a do-not-run directive inside it.'],
        'noop.t excluded with the do-not-run message',
    );
    is([$f->exclude_file($long)],  [], 'long.t not excluded without filters');
    is([$f->exclude_file($short)], [], 'short.t not excluded without filters');
};

subtest 'no_long=1 drops DURATION-LONG fixtures' => sub {
    my $f = finder(no_long => 1);
    is(
        [$f->exclude_file($long)],
        ['File is marked as "long", but the "no long tests" opition was specified.'],
        'long.t excluded under --no-long',
    );
    is([$f->exclude_file($short)], [], 'short.t still included under --no-long');
};

subtest 'only_long=1 drops non-long fixtures' => sub {
    my $f = finder(only_long => 1);
    is(
        [$f->exclude_file($short)],
        ['File is not marked "long", but the "only long tests" option was specified.'],
        'short.t excluded under --only-long',
    );
    is([$f->exclude_file($long)], [], 'long.t still included under --only-long');
};

subtest 'check_feature / check_duration are evaluated end-to-end' => sub {
    # Cross-check: the Finder's decisions actually come from the
    # TestFile helpers, not from any stray state on the Finder itself.
    is($noop->check_feature('run'),  0,        'noop.t: run feature disabled');
    is($long->check_duration,        'long',   'long.t: duration classified as long');
    is($short->check_duration,       'medium', 'short.t: duration falls back to medium');
    is($short->check_feature('run'), 1,        'short.t: run feature enabled by default');
};

done_testing;
