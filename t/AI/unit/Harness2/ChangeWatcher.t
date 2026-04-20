use Test2::V0;

use File::Temp qw/tempfile/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::ChangeWatcher::Stat;

subtest 'Stat: viable' => sub {
    ok(
        Test2::Harness2::ChangeWatcher::Stat->viable,
        'stat backend is always viable'
    );
};

subtest 'Stat: watch + changed_files' => sub {
    my ($fh, $file) = tempfile(UNLINK => 1);
    print $fh "initial\n";
    close($fh);

    my $w = Test2::Harness2::ChangeWatcher::Stat->new(
        min_interval => 0,
    );
    $w->watch($file);

    # First poll: nothing changed.
    my $changed = $w->changed_files;
    is($changed, [], 'no change on first poll');

    # Touch the file with a new mtime.
    sleep 1.1;    # ensure stat resolution sees the update
    open(my $wfh, '>>', $file) or die $!;
    print $wfh "more\n";
    close($wfh);

    $changed = $w->changed_files;
    is(scalar(@$changed), 1, 'one change detected')
        or diag explain $changed;
};

subtest 'Stat: rate limiting' => sub {
    my ($fh, $file) = tempfile(UNLINK => 1);
    print $fh "initial\n";
    close($fh);

    my $w = Test2::Harness2::ChangeWatcher::Stat->new(
        min_interval => 5,
    );
    $w->watch($file);

    my $first  = $w->changed_files;
    my $second = $w->changed_files;

    is($first,  [],    'first poll: empty array');
    is($second, undef, 'rapid second poll returns undef (rate-limited)');
};

subtest 'Stat: stop clears state' => sub {
    my ($fh, $file) = tempfile(UNLINK => 1);
    print $fh "hello\n";
    close($fh);

    my $w = Test2::Harness2::ChangeWatcher::Stat->new(min_interval => 0);
    $w->watch($file);
    $w->stop;

    is($w->watches, {}, 'stop clears watches');
    is($w->times,   {}, 'stop clears cached times');
};

subtest 'Inotify: viable is environment-dependent' => sub {
    require Test2::Harness2::ChangeWatcher::Inotify;
    my $v = Test2::Harness2::ChangeWatcher::Inotify->viable;
    ok(defined $v, 'viable returns a defined value');

    if ($v) {
        my $w = Test2::Harness2::ChangeWatcher::Inotify->new;
        isa_ok(
            $w, ['Test2::Harness2::ChangeWatcher::Inotify'],
            'inotify watcher constructs'
        );
    }
    else {
        like(
            dies { Test2::Harness2::ChangeWatcher::Inotify->new },
            qr/Linux::Inotify2 is not installed/,
            'non-viable inotify refuses construction',
        );
    }
};

done_testing;
