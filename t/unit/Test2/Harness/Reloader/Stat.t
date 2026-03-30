use Test2::V0 -target => 'Test2::Harness::Reloader::Stat';
use File::Temp qw/tempfile/;

subtest construction => sub {
    local $ENV{T2_HARNESS_STAGE} = undef;
    my $r = CLASS->new(stage_name => 'test');
    ok($r, "constructed");
    is(ref($r->times), 'HASH', "times is a hashref");
    is($r->last_check_stamp, 0, "last_check_stamp starts at 0");
};

subtest stage_name => sub {
    # stage_name is passed through the 'stage' key (string form) in base init
    my $r = bless { stage_name => 'mytest', restrict => [], watches => {}, watched => {}, times => {}, last_check_stamp => 0 },
        CLASS;
    is($r->stage_name, 'mytest', "stage_name accessor returns correct value");
};

subtest changed_files_no_changes => sub {
    my $r = CLASS->new(stage_name => 'test');

    # Force last_check_stamp to zero so the delta check is bypassed
    $r->{last_check_stamp} = 0;

    # watched is an empty hash so nothing to compare
    my $result = $r->changed_files;
    ok(ref($result) eq 'ARRAY', "changed_files returns an arrayref when no files are watched");
    is(scalar @$result, 0, "empty list when nothing is watched");
};

subtest watch_and_changed_files => sub {
    # Create a temporary file to watch
    my ($fh, $filename) = tempfile(SUFFIX => '.pm', UNLINK => 1);
    print $fh "# placeholder\n";
    close $fh;

    my $r = CLASS->new(stage_name => 'stat_test');

    # Manually register the file as watched (mimicking what start() does via do_watch)
    $r->{times}{$filename}   = $r->_get_file_times($filename);
    $r->{watched}{$filename} = 1;

    # Force last_check_stamp to 0 so changed_files will run
    $r->{last_check_stamp} = 0;

    my $changed = $r->changed_files;
    ok(ref($changed) eq 'ARRAY', "changed_files returns arrayref");
    is(scalar(grep { $_ eq $filename } @$changed), 0, "unchanged file not reported");

    # Modify the file so mtime changes
    sleep 1;
    open(my $wfh, '>', $filename) or die "Cannot write: $!";
    print $wfh "# modified\n";
    close $wfh;

    # Reset stamp so changed_files will run again
    $r->{last_check_stamp} = 0;

    $changed = $r->changed_files;
    ok(ref($changed) eq 'ARRAY', "changed_files returns arrayref after modification");
    is(scalar(grep { $_ eq $filename } @$changed), 1, "modified file is reported as changed");
};

done_testing;
