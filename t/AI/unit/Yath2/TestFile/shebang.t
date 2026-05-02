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
    my ($name, $content) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    write_file($path, $content);
    return App::Yath2::TestFile->new(file => $path);
}

# Any constructed TestFile is a valid invocant for _parse_shbang; the
# tests below use it purely as a method receiver. App::Yath2::TestFile
# refuses construction for missing files, so write a placeholder first.
my $invocant_path = File::Spec->catfile($tdir, 'any.t');
write_file($invocant_path, '');
my $invocant = App::Yath2::TestFile->new(file => $invocant_path);

subtest '_parse_shbang direct API' => sub {
    is(
        $invocant->_parse_shbang("#!/usr/bin/perl\n"),
        {line => "#!/usr/bin/perl\n", switches => []},
        'plain perl shebang -> empty switches arrayref',
    );

    is(
        $invocant->_parse_shbang("#!/usr/bin/perl -w\n"),
        {line => "#!/usr/bin/perl -w\n", switches => ['-w']},
        'single switch',
    );

    is(
        $invocant->_parse_shbang("#!/usr/bin/env perl -t -w\n"),
        {line => "#!/usr/bin/env perl -t -w\n", switches => ['-t', '-w']},
        'env perl with two switches',
    );

    is(
        $invocant->_parse_shbang("#!/usr/bin/perl -Mblib\n"),
        {line => "#!/usr/bin/perl -Mblib\n", switches => ['-Mblib']},
        'module switch',
    );

    is(
        $invocant->_parse_shbang("#!/usr/bin/bash\n"),
        {line => "#!/usr/bin/bash\n", non_perl => 1},
        'plain non-perl shebang -> non_perl flagged, no switches key',
    );

    is(
        $invocant->_parse_shbang("#!/usr/bin/env bash\n"),
        {line => "#!/usr/bin/env bash\n", non_perl => 1},
        'env bash -> non_perl',
    );

    is($invocant->_parse_shbang(undef),           {}, 'undef input -> empty hashref');
    is($invocant->_parse_shbang("use strict;\n"), {}, 'no shebang -> empty hashref');
};

subtest 'end-to-end scan: #!/usr/bin/perl with no switches' => sub {
    my $tf = tf_for('plain.t', "#!/usr/bin/perl\nuse strict;\n");
    $tf->scan;
    is($tf->switches,                                    [],                  'switches stays empty');
    is($tf->non_perl,                                    0,                   'non_perl stays 0');
    is($tf->{+App::Yath2::TestFile::_SHBANG}{line}, "#!/usr/bin/perl", '_shbang line captured (chomp\'d)');
    ok(exists $tf->{+App::Yath2::TestFile::_SHBANG}{switches},  '_shbang has switches key');
    ok(!exists $tf->{+App::Yath2::TestFile::_SHBANG}{non_perl}, '_shbang has no non_perl key');
};

subtest 'end-to-end scan: #!/usr/bin/perl -w populates switches' => sub {
    my $tf = tf_for('dashw.t', "#!/usr/bin/perl -w\nuse strict;\n");
    $tf->scan;
    is($tf->switches, ['-w'], 'switches == [-w]');
    is($tf->non_perl, 0,      'non_perl stays 0');
};

subtest 'end-to-end scan: #!/usr/bin/env perl -t -w' => sub {
    my $tf = tf_for('tw.t', "#!/usr/bin/env perl -t -w\nuse strict;\n");
    $tf->scan;
    is($tf->switches, ['-t', '-w'], 'both switches preserved in order');
    is($tf->non_perl, 0,            'non_perl stays 0');
};

subtest 'end-to-end scan: #!/usr/bin/bash sets non_perl' => sub {
    my $tf = tf_for('bash.t', "#!/usr/bin/bash\necho hi\n");
    $tf->scan;
    is($tf->switches, [], 'switches stays empty (role default)');
    is($tf->non_perl, 1,  'non_perl flagged');
    ok($tf->{+App::Yath2::TestFile::_SHBANG}{non_perl}, '_shbang carries non_perl');
};

subtest 'end-to-end scan: no shebang leaves slots at role defaults' => sub {
    my $tf = tf_for('noshbang.t', "use strict;\nmy \$x = 1;\n");
    $tf->scan;
    is($tf->switches, [], 'switches default []');
    is($tf->non_perl, 0,  'non_perl default 0');
    ok(
               !$tf->{+App::Yath2::TestFile::_SHBANG}
            || !%{$tf->{+App::Yath2::TestFile::_SHBANG}},
        '_shbang is falsy/empty',
    );
};

subtest 'end-to-end scan: HARNESS- directive on line 1 is not a shebang' => sub {
    my $tf = tf_for('directive_first.t', "# HARNESS-NO-FORK\nuse strict;\n");
    $tf->scan;
    is($tf->switches, [], 'switches untouched');
    is($tf->non_perl, 0,  'non_perl untouched');
    ok(
               !$tf->{+App::Yath2::TestFile::_SHBANG}
            || !%{$tf->{+App::Yath2::TestFile::_SHBANG}},
        '_shbang remains empty',
    );
};

done_testing;
