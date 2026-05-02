use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::TestFile;

my $tdir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    binmode($fh);
    print {$fh} $content;
    close($fh);
    return $path;
}

sub tf_for {
    my ($name, $content) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    write_file($path, $content);
    return App::Yath2::TestFile->new(file => $path);
}

subtest 'binary file: _scan short-circuits and flags is_binary + non_perl' => sub {
    my $bytes = pack 'C*', map { int rand 256 } 1 .. 512;
    my $path  = File::Spec->catfile($tdir, 'bin.t');
    write_file($path, $bytes);
    # App::Yath2::TestFile refuses non-executable binaries (legacy
    # idiom); flip the bit before construction.
    chmod 0755, $path or die "chmod $path: $!";
    my $tf = App::Yath2::TestFile->new(file => $path);

    $tf->scan;

    is($tf->is_binary, 1,  'is_binary set');
    is($tf->non_perl,  1,  'non_perl set');
    is($tf->switches,  [], 'switches untouched (scan short-circuited before shebang)');
};

subtest 'empty file is not binary (-z exemption)' => sub {
    my $tf = tf_for('empty.t', '');

    $tf->scan;

    is($tf->is_binary, 0, 'is_binary stays 0');
    is($tf->non_perl,  0, 'non_perl stays 0');
};

subtest 'generated runner sentinel sets features->{run} = 0' => sub {
    # Stage F will tighten the next-vs-last guarantee by appending a
    # post-sentinel `# HARNESS-*` directive and asserting it took effect
    # (e.g. category / duration). For Stage C the best we can prove is
    # that scan() returns cleanly past the sentinel and _scanned latches.
    my $tf = tf_for(
        'generated.t',
        "#!/usr/bin/perl\n" . "# THIS IS A GENERATED YATH RUNNER TEST\n" . "use strict;\n",
    );

    ok(lives { $tf->scan }, 'scan did not die past the sentinel') or diag($@);

    is($tf->{+App::Yath2::TestFile::_SCANNED}, 1, '_scanned latched');
    is($tf->feature('run'), 0, 'features->{run} set to 0');
    is($tf->switches,       [], 'shebang branch still ran: switches at role default');
    is($tf->non_perl,       0,  'perl shebang: non_perl stays 0');
};

subtest 'sentinel with leading whitespace and spacing still matches' => sub {
    my $tf = tf_for(
        'generated_ws.t',
        "   #   THIS IS A GENERATED YATH RUNNER TEST\n" . "use strict;\n",
    );

    $tf->scan;

    is($tf->feature('run'), 0, 'features->{run} set to 0');
};

done_testing;
