use Test2::V0;

use File::Temp qw/tempdir/;
use App::Yath2::LogArchive::Artifact;

# Build a minimal LogArchive-shaped backend that satisfies the
# Artifact's needs: static() and absolute_path($rel). Two flavours:
# a live backend (where ->watch wraps a FileMonitor that drives a
# real stat loop) and a static backend (where ->watch returns a
# FileMonitor in static mode whose change signal is one-shot).

package T2H2_FakeLiveArchive;
use Object::HashBase qw/path/;
sub is_live       { 1 }
sub static        { 0 }
sub absolute_path { my ($s, $rel) = @_; "$s->{+PATH}/$rel" }
sub has_file      { my ($s, $rel) = @_; -f "$s->{+PATH}/$rel" }

package T2H2_FakeStaticArchive;
use Object::HashBase qw/path/;
sub is_live       { 0 }
sub static        { 1 }
sub absolute_path { my ($s, $rel) = @_; "$s->{+PATH}/$rel" }
sub has_file      { my ($s, $rel) = @_; -f "$s->{+PATH}/$rel" }

package main;

my $dir = tempdir(CLEANUP => 1);

# Plain JSON snapshot file -- exercise update_type='replace' /
# ->data on a static backend, plus ->watch's static one-shot signal.
{
    my $path = "$dir/state.json";
    open(my $fh, '>', $path) or die $!;
    print $fh '{"hello":"world","n":42}';
    close $fh;

    my $arc = T2H2_FakeStaticArchive->new(path => $dir);
    my $a   = App::Yath2::LogArchive::Artifact->new(
        archive      => $arc,
        relpath      => 'state.json',
        logger_class => 'Test2::Harness2::Collector::Logger::JSON',
        update_type  => 'replace',
    );

    # data() returns the decoded content.
    is($a->data, {hello => 'world', n => 42}, 'static replace ->data');

    # ->watch returns a fresh FileMonitor in static mode. Two
    # successive ->watch calls produce independent monitors (no
    # internal caching): consuming the change on one does not
    # consume it on the other.
    my $w1 = $a->watch;
    my $w2 = $a->watch;
    ok($w1->static,          'static archive -> static monitor');
    is($w1->changed,      $a, 'static: first changed() is the artifact');
    is($w1->changed,      0,  'static: second changed() is 0');
    is($w1->peek_changed, 0,  'static: peek_changed() after change is 0');
    is($w2->changed,      $a, 'fresh watcher still has its one-shot change');
}

# Plain JSONL events file -- exercise update_type='append' / ->next
# on a static backend.
{
    my $path = "$dir/events.jsonl";
    open(my $fh, '>', $path) or die $!;
    print $fh "{\"event_id\":\"E1\"}\n";
    print $fh "{\"event_id\":\"E2\"}\n";
    print $fh "{\"event_id\":\"E3\"}\n";
    close $fh;

    my $arc = T2H2_FakeStaticArchive->new(path => $dir);
    my $a   = App::Yath2::LogArchive::Artifact->new(
        archive      => $arc,
        relpath      => 'events.jsonl',
        logger_class => 'Test2::Harness2::Collector::Logger::JSONL',
        update_type  => 'append',
    );

    my @drained;
    while (defined(my $e = $a->next)) {
        push @drained => $e;
    }

    is(scalar(@drained), 3, 'static append ->next drained 3 events');
    is(
        [map { $_->{event_id} } @drained],
        ['E1', 'E2', 'E3'],
        'events come back in order',
    );
}

# Live backend: ->watch yields a real FileMonitor that observes
# subsequent rewrites of the file.
{
    my $path = "$dir/live.json";
    open(my $fh, '>', $path) or die $!;
    print $fh '{"v":1}';
    close $fh;

    my $arc = T2H2_FakeLiveArchive->new(path => $dir);
    my $a   = App::Yath2::LogArchive::Artifact->new(
        archive      => $arc,
        relpath      => 'live.json',
        logger_class => 'Test2::Harness2::Collector::Logger::JSON',
        update_type  => 'replace',
    );

    my $w = $a->watch;
    ok(!$w->static,    'live archive -> non-static monitor');
    ok($w->changed,    'live: first changed() truthy');
    ok(!$w->changed,   'live: second changed() is 0 (no rewrite)');

    # Touch the file to invalidate the FileMonitor's cached state.
    # FileMonitor uses dev/inode/size/mtime; rewrite with a different
    # size to make the change unmistakable.
    sleep 1;    # crude but reliable mtime-tick guarantee on coarse FSes
    open(my $rfh, '>', $path) or die $!;
    print $rfh '{"v":222222}';
    close $rfh;

    ok($w->changed, 'live: changed() reports the rewrite');
}

# Bad construction.
{
    like(
        dies {
            App::Yath2::LogArchive::Artifact->new(
                archive      => T2H2_FakeStaticArchive->new(path => $dir),
                relpath      => 'x',
                logger_class => 'Foo',
                update_type  => 'sometimes',
            );
        },
        qr/Invalid update_type/,
        'invalid update_type rejected',
    );

    like(
        dies {
            App::Yath2::LogArchive::Artifact->new(
                relpath      => 'x',
                logger_class => 'Foo',
                update_type  => 'append',
            );
        },
        qr/'archive' is a required attribute/,
        'missing archive rejected',
    );
}

# Calling ->data on an append artifact (or ->next on a replace
# artifact) is a programming error.
{
    my $arc = T2H2_FakeStaticArchive->new(path => $dir);
    my $a   = App::Yath2::LogArchive::Artifact->new(
        archive      => $arc,
        relpath      => 'events.jsonl',
        logger_class => 'Test2::Harness2::Collector::Logger::JSONL',
        update_type  => 'append',
    );
    like(
        dies { $a->data },
        qr/->data is only valid on update_type='replace'/,
        '->data on append artifact croaks',
    );
}

done_testing;
