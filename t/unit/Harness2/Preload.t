use Test2::V0;
use strict;
use warnings;

# Build a pretend preload library on the fly using the DSL, then inspect the
# meta-object to ensure the stage tree matches what was described.

package My::TestPreload;
use Test2::Harness2::Preload;
our $RAN_CODE = 0;

stage Moose => sub {
    preload 'Scalar::Util';
    preload 'List::Util';
    preload sub { $My::TestPreload::RAN_CODE++ };

    pre_fork   sub { };
    post_fork  sub { };
    pre_launch sub { };

    eager();
    default();

    stage Types => sub {
        preload 'Carp';
    };
};

stage Moo => sub {
    preload 'Scalar::Util';
};

package main;

my $meta = My::TestPreload::TEST2_HARNESS_PRELOAD();
isa_ok($meta, ['Test2::Harness2::Preload'], "meta object");

subtest "stage_list + stage_lookup" => sub {
    my @roots = map { $_->name } @{$meta->stage_list};
    is(\@roots, [qw/Moose Moo/], "two roots in declaration order");

    is([sort keys %{$meta->stage_lookup}], [qw/Moo Moose Types/], "all stages indexed");
};

subtest "nested stage" => sub {
    my $moose = $meta->stage_lookup->{Moose};
    is(scalar @{$moose->children}, 1, "one nested stage under Moose");
    is($moose->children->[0]->name, 'Types', "nested name correct");
};

subtest "load_sequence preserves order" => sub {
    my $moose = $meta->stage_lookup->{Moose};
    my @seq   = @{$moose->load_sequence};
    is($seq[0], 'Scalar::Util', "first preload");
    is($seq[1], 'List::Util',   "second preload");
    is(ref $seq[2], 'CODE',     "third is a coderef");
};

subtest "eager + default" => sub {
    my $moose = $meta->stage_lookup->{Moose};
    ok($moose->eager, "Moose marked eager");
    is($meta->default_stage, 'Moose', "default stage is Moose");
};

subtest "callbacks populated" => sub {
    my $moose = $meta->stage_lookup->{Moose};
    is(scalar @{$moose->pre_fork_callbacks},   1, "one pre_fork");
    is(scalar @{$moose->post_fork_callbacks},  1, "one post_fork");
    is(scalar @{$moose->pre_launch_callbacks}, 1, "one pre_launch");
};

subtest "duplicate stage name" => sub {
    my $code = q{
        package My::Bad::Preload;
        use Test2::Harness2::Preload;
        stage Dup => sub { preload 'Carp' };
        stage Dup => sub { preload 'Carp' };
        1;
    };
    my $err = dies { eval $code or die $@ };
    like($err, qr/A stage named 'Dup' was already defined/, "duplicate detected");
};

subtest "DSL calls outside stage" => sub {
    my $eager = q{
        package My::OutsidePreload::Eager;
        use Test2::Harness2::Preload;
        eager();
        1;
    };
    like(dies { eval $eager or die $@ }, qr/No current stage/, "eager outside stage errors");

    my $preload = q{
        package My::OutsidePreload::Preload;
        use Test2::Harness2::Preload;
        preload 'Foo';
        1;
    };
    like(dies { eval $preload or die $@ }, qr/No current stage/, "preload outside stage errors");

    my $prefork = q{
        package My::OutsidePreload::PreFork;
        use Test2::Harness2::Preload;
        pre_fork sub { };
        1;
    };
    like(dies { eval $prefork or die $@ }, qr/No current stage/, "pre_fork outside stage errors");

    my $watch = q{
        package My::OutsidePreload::Watch;
        use Test2::Harness2::Preload;
        watch '/no/such/file', sub { };
        1;
    };
    like(dies { eval $watch or die $@ }, qr/No current stage/, "watch outside w/o reloader errors");
};

subtest "file_stage / add_file_stage are deprecated" => sub {
    my $meta2 = Test2::Harness2::Preload->new;
    like(dies { $meta2->file_stage }, qr/deprecated/, "file_stage deprecated");
    like(dies { $meta2->add_file_stage }, qr/deprecated/, "add_file_stage deprecated");
};

done_testing;
