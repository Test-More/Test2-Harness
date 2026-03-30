use Test2::Require::Module 'Linux::Inotify2';
use Test2::V0 -target => 'Test2::Harness::Reloader::Inotify2';

# Linux::Inotify2 is available (Test2::Require::Module already skipped otherwise)

subtest isa => sub {
    ok(CLASS->isa('Test2::Harness::Reloader'), "is a Reloader subclass");
};

subtest construction => sub {
    my $r = CLASS->new(stage => 'inotify_test');
    ok($r, "constructed");
    is($r->stage_name, 'inotify_test', "stage_name accessor");
    is($r->watcher, undef, "watcher is undef before start");
};

subtest changed_files_requires_start => sub {
    my $r = CLASS->new(stage => 'test');

    like(
        dies { $r->changed_files },
        qr/not started/i,
        "changed_files croaks before start is called"
    );
};

subtest start_sets_watcher => sub {
    my $r = CLASS->new(stage => 'test');
    $r->start;
    ok($r->watcher, "watcher set after start");
    ok($r->watcher->isa('Linux::Inotify2'), "watcher is a Linux::Inotify2 instance");
    $r->stop;
};

subtest stop_clears_watcher => sub {
    my $r = CLASS->new(stage => 'test');
    $r->start;
    $r->stop;
    is($r->watcher, undef, "watcher cleared after stop");
};

subtest changed_files_returns_arrayref => sub {
    my $r = CLASS->new(stage => 'test');
    $r->start;
    my $changed = $r->changed_files;
    ok(ref($changed) eq 'ARRAY', "changed_files returns an arrayref");
    $r->stop;
};

done_testing;
