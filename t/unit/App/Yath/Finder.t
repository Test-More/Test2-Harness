use Test2::V0 -target => 'App::Yath::Finder';

use File::Temp qw/tempfile/;

subtest 'parse_test_item extracts path and test params' => sub {
    # :@ (argv)
    my ($path, $params) = App::Yath::Finder::parse_test_item('test.pl:@["arg1","arg2"]');
    is $path, 'test.pl', ':@ path extracted correctly';
    is $params->{argv}, [qw/arg1 arg2/], ':@ argv params decoded correctly';

    # :< (stdin)
    ($path, $params) = App::Yath::Finder::parse_test_item('test.pl:<some_input');
    is $path, 'test.pl', ':< path extracted correctly';
    is $params->{stdin}, 'some_input', ':< stdin param extracted correctly';

    # := (env)
    ($path, $params) = App::Yath::Finder::parse_test_item('test.pl:={"FOO":"bar"}');
    is $path, 'test.pl', ':= path extracted correctly';
    is $params->{env}, {FOO => 'bar'}, ':= env params decoded correctly';

    # plain path (no separator)
    ($path, $params) = App::Yath::Finder::parse_test_item('test.pl');
    is $path, 'test.pl', 'plain path extracted correctly';
    is $params, undef, 'plain path has no test params';
};

subtest 'find_project_files parses test params from input' => sub {
    my ($fh, $tmpfile) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "use Test2::V0;\nok(1);\ndone_testing;\n";
    close $fh;

    my $settings = mock {} => (
        add => [
            check_group => sub { 0 },
        ],
    );

    my $finder = $CLASS->new(
        settings       => $settings,
        default_search => [],
    );

    # :@ (argv) — exercises the actual split in find_project_files
    my $tests = $finder->find_project_files([], ["${tmpfile}:@" . '["arg1","arg2"]']);
    is scalar(@$tests), 1, ':@ input yields one test file';
    is $tests->[0]->test_settings->args, [qw/arg1 arg2/], ':@ argv params parsed correctly';

    # :< (stdin)
    $tests = $finder->find_project_files([], ["${tmpfile}:<hello"]);
    is scalar(@$tests), 1, ':< input yields one test file';
    is $tests->[0]->test_settings->input, 'hello', ':< stdin param parsed correctly';

    # := (env)
    $tests = $finder->find_project_files([], ["${tmpfile}:=" . '{"FOO":"bar"}']);
    is scalar(@$tests), 1, ':= input yields one test file';
    is $tests->[0]->test_settings->env_vars->{FOO}, 'bar', ':= env params parsed correctly';

    # plain path (no separator)
    $tests = $finder->find_project_files([], [$tmpfile]);
    is scalar(@$tests), 1, 'plain path yields one test file';
};

done_testing;
