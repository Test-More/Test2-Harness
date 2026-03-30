use Test2::V0 -target => 'Test2::Harness::TestFile';
use File::Temp qw/tempfile/;

sub make_test_file {
    my ($content) = @_;
    my ($fh, $file) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh $content // "# empty test\n";
    close $fh;
    return $file;
}

subtest 'requires valid file' => sub {
    like(
        dies { $CLASS->new(file => '/no/such/file/xyz.t') },
        qr/Invalid test file/,
        'dies for non-existent file',
    );
};

subtest 'basic construction' => sub {
    my $file = make_test_file("use Test2::V0;\ndone_testing;\n");
    my $tf = $CLASS->new(file => $file);
    ok($tf->isa($CLASS), 'creates instance');
    ok($tf->file, 'file accessor returns value');
    ok(-f $tf->file, 'file exists on disk');
};

subtest 'relative path' => sub {
    my $file = make_test_file("# test\n");
    my $tf = $CLASS->new(file => $file);
    ok(defined($tf->relative), 'relative() returns a defined value');
};

subtest 'check_feature defaults' => sub {
    my $file = make_test_file("# plain test\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_feature('fork'),      1, 'fork defaults to 1');
    is($tf->check_feature('preload'),   1, 'preload defaults to 1');
    is($tf->check_feature('stream'),    1, 'stream defaults to 1');
    is($tf->check_feature('run'),       1, 'run defaults to 1');
    is($tf->check_feature('timeout'),   1, 'timeout defaults to 1');
    is($tf->check_feature('isolation'), 0, 'isolation defaults to 0');
    is($tf->check_feature('smoke'),     0, 'smoke defaults to 0');
};

subtest 'HARNESS-NO-FORK disables fork feature' => sub {
    my $file = make_test_file("# HARNESS-NO-FORK\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_feature('fork'), 0, 'fork disabled by HARNESS-NO-FORK');
};

subtest 'HARNESS-NO-PRELOAD disables preload feature' => sub {
    my $file = make_test_file("# HARNESS-NO-PRELOAD\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_feature('preload'), 0, 'preload disabled by HARNESS-NO-PRELOAD');
};

subtest 'HARNESS-DURATION sets duration' => sub {
    my $file = make_test_file("# HARNESS-DURATION-LONG\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_duration, 'long', 'duration set to long');
};

subtest 'HARNESS-CATEGORY sets category' => sub {
    my $file = make_test_file("# HARNESS-CATEGORY-ISOLATION\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_category, 'isolation', 'category set to isolation');
};

subtest 'check_duration defaults to medium (timeout enabled)' => sub {
    my $file = make_test_file("# plain\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_duration, 'medium', 'default duration is medium when timeout enabled');
};

subtest 'check_duration is long when timeout disabled' => sub {
    my $file = make_test_file("# HARNESS-NO-TIMEOUT\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_duration, 'long', 'duration is long when no timeout');
};

subtest 'check_category defaults to general' => sub {
    my $file = make_test_file("# plain\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->check_category, 'general', 'default category is general');
};

subtest 'HARNESS-CONFLICTS sets conflicts list' => sub {
    # Conflicts are stored lowercase
    my $file = make_test_file("# HARNESS-CONFLICTS foo::bar baz::qux\n");
    my $tf = $CLASS->new(file => $file);
    my $conflicts = $tf->conflicts_list;
    ref_ok($conflicts, 'ARRAY', 'conflicts_list returns arrayref');
    ok(scalar(grep { $_ eq 'foo::bar' } @$conflicts), 'foo::bar in conflicts');
};

subtest 'conflicts_list returns empty arrayref when no conflicts' => sub {
    my $file = make_test_file("# plain\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->conflicts_list, [], 'empty conflicts list');
};

subtest 'HARNESS-TIMEOUT-EVENT sets event timeout' => sub {
    my $file = make_test_file("# HARNESS-TIMEOUT-EVENT 120\n");
    my $tf = $CLASS->new(file => $file);
    is($tf->event_timeout, 120, 'event_timeout set to 120');
};

subtest 'HARNESS-META stores metadata' => sub {
    my $file = make_test_file("# HARNESS-META-mykey myvalue\n");
    my $tf = $CLASS->new(file => $file);
    my @vals = $tf->meta('mykey');
    ok(scalar(@vals), 'meta returns values for known key');
    is($vals[0], 'myvalue', 'meta value matches');
};

subtest 'set_duration and set_category' => sub {
    my $file = make_test_file("# plain\n");
    my $tf = $CLASS->new(file => $file);
    $tf->set_duration('long');
    is($tf->check_duration, 'long', 'set_duration works');
    $tf->set_category('immiscible');
    is($tf->check_category, 'immiscible', 'set_category works');
};

done_testing;
