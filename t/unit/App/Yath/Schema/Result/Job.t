use Test2::V0; # -target => 'App::Yath::Schema::Result::Job'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

# SQLite loading triggers load_namespaces which loads all result classes + overlays.
# We test overlay methods by creating mock objects that override DB-specific calls.

{
    package Test::MockJob;
    our @ISA = ('App::Yath::Schema::Result::Job');
    sub new       { bless {%{$_[1]}}, $_[0] }
    sub get_all_fields { %{$_[0]} }
    sub test_file { $_[0]->{_test_file} }
    sub job_tries  { @{$_[0]->{_tries} // []} }
    sub jobs_tries { @{$_[0]->{_tries} // []} }
}

isa_ok('App::Yath::Schema::Result::Job', ['App::Yath::Schema::ResultBase'], 'inherits from ResultBase');

can_ok('App::Yath::Schema::Result::Job', [qw/file short_file shortest_file complete TO_JSON/], 'has overlay methods');

subtest 'file() from columns' => sub {
    my $job = Test::MockJob->new({file => '/path/to/t/foo.t'});
    is($job->file, '/path/to/t/foo.t', "file from 'file' column");

    my $job2 = Test::MockJob->new({filename => '/path/to/bar.t'});
    is($job2->file, '/path/to/bar.t', "file from 'filename' column");

    my $job3 = Test::MockJob->new({});
    is($job3->file, undef, "file returns undef when no column and no relationship");
};

subtest 'short_file()' => sub {
    my $cases = [
        ['/repo/t/foo.t',          't/foo.t',       "t/ directory"],
        ['/repo/t2/foo.t',         't2/foo.t',       "t2/ directory"],
        ['/repo/src/foo.pl',       'foo.pl',         ".pl file"],
        ['/repo/src/test.t',       'test.t',         ".t file in non-t dir"],
        ['/repo/plain',            '/repo/plain',    "no extension, no match"],
    ];

    for my $case (@$cases) {
        my ($path, $expected, $desc) = @$case;
        my $job = Test::MockJob->new({file => $path});
        is($job->short_file, $expected, $desc);
    }

    my $no_file = Test::MockJob->new({});
    is($no_file->short_file, undef, "short_file returns undef when no file");
};

subtest 'shortest_file()' => sub {
    my $job = Test::MockJob->new({file => '/long/path/to/foo.t'});
    is($job->shortest_file, 'foo.t', "basename extracted");

    my $no_file = Test::MockJob->new({});
    is($no_file->shortest_file, undef, "returns undef when no file");
};

subtest 'complete()' => sub {
    # No tries -> not complete
    my $no_tries = Test::MockJob->new({_tries => []});
    ok(!$no_tries->complete, "no tries means not complete");

    # One complete try, no retry
    {
        package Test::MockTry;
        sub complete { 1 }
        sub retry    { 0 }
    }
    my $one_done = Test::MockJob->new({_tries => [bless {}, 'Test::MockTry']});
    ok($one_done->complete, "one complete try with no retry is complete");

    # Incomplete try
    {
        package Test::MockTryFail;
        sub complete { 0 }
        sub retry    { 0 }
    }
    my $one_fail = Test::MockJob->new({_tries => [bless {}, 'Test::MockTryFail']});
    ok(!$one_fail->complete, "one incomplete try is not complete");
};

subtest 'TO_JSON()' => sub {
    my $job = Test::MockJob->new({job_uuid => 'abc-123', is_harness_out => 0});
    my $json = $job->TO_JSON;
    ref_ok($json, 'HASH', 'TO_JSON returns hashref');
    ok(exists $json->{short_file},    'short_file key present');
    ok(exists $json->{shortest_file}, 'shortest_file key present');
};

done_testing;
