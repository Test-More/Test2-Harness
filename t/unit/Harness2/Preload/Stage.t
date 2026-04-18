use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempfile/;
use File::Spec ();

use Test2::Harness2::Preload::Stage;

subtest "required name" => sub {
    like(
        dies { Test2::Harness2::Preload::Stage->new() },
        qr/'name' is a required attribute/,
        "name must be given",
    );
};

subtest "reserved names" => sub {
    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'base') },
        qr/Stage name 'base' is reserved/,
        "base is reserved",
    );

    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'NOPRELOAD') },
        qr/Stage name 'NOPRELOAD' is reserved/,
        "NOPRELOAD is reserved",
    );
};

subtest "defaults" => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'Moose');
    is($s->name, 'Moose', "name stored");
    is($s->children, [], "empty children");
    is($s->pre_fork_callbacks,   [], "empty pre_fork");
    is($s->post_fork_callbacks,  [], "empty post_fork");
    is($s->pre_launch_callbacks, [], "empty pre_launch");
    is($s->load_sequence,        [], "empty load_sequence");
    is($s->watches,              {}, "empty watches");
    is($s->eager, undef, "eager undef by default");
    ok($s->frame, "frame captured");
};

subtest "callbacks and load sequence" => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'Moo');

    my @pre;
    $s->add_pre_fork_callback(sub { push @pre => \@_ });
    $s->add_post_fork_callback(sub { });
    $s->add_pre_launch_callback(sub { });

    $s->add_to_load_sequence('Foo', 'Bar', sub { 1 });

    is(scalar @{$s->pre_fork_callbacks},   1, "one pre_fork cb");
    is(scalar @{$s->post_fork_callbacks},  1, "one post_fork cb");
    is(scalar @{$s->pre_launch_callbacks}, 1, "one pre_launch cb");
    is(scalar @{$s->load_sequence},        3, "load sequence of 3");

    $s->do_pre_fork(1, 2);
    is(\@pre, [[1, 2]], "pre_fork called with args");

    like(
        dies { $s->add_pre_fork_callback("not a coderef") },
        qr/Callback must be a coderef/,
        "reject non-coderef",
    );

    like(
        dies { $s->add_to_load_sequence({not => 'ok'}) },
        qr/not a valid preload/,
        "reject invalid load item",
    );
};

subtest "watch" => sub {
    my ($fh, $path) = tempfile();
    close $fh;

    my $s = Test2::Harness2::Preload::Stage->new(name => 'W');
    my $cb = sub { };
    $s->watch($path, $cb);

    my $abs = File::Spec->rel2abs($path);
    is($s->watches->{$abs}, $cb, "watch registered under absolute path");

    like(
        dies { $s->watch($path, sub { }) },
        qr/already a watch/,
        "duplicate watch rejected",
    );

    like(
        dies { $s->watch("/no/such/file", sub { }) },
        qr/must be a file/,
        "missing file rejected",
    );

    like(
        dies { $s->watch($path, "not a code") },
        qr/callback argument is required/,
        "non-code callback rejected",
    );

    unlink $path;
};

subtest "add_child / all_children" => sub {
    my $root = Test2::Harness2::Preload::Stage->new(name => 'A');
    my $b    = Test2::Harness2::Preload::Stage->new(name => 'B');
    my $c    = Test2::Harness2::Preload::Stage->new(name => 'C');
    my $d    = Test2::Harness2::Preload::Stage->new(name => 'D');

    $root->add_child($b);
    $root->add_child($c);
    $b->add_child($d);

    is([map { $_->name } @{$root->all_children}], [qw/B C D/], "depth-first descendants");
};

done_testing;
