use Test2::V0; # -target => 'App::Yath::Schema::Result::Run'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

{
    package Test::MockRun;
    our @ISA = ('App::Yath::Schema::Result::Run');
    sub new           { bless {%{$_[1]}}, $_[0] }
    sub get_all_fields { %{$_[0]} }
    sub status        { $_[0]->{status} }
    sub parameters    { $_[0]->{parameters} }
    sub run_fields    {
        my $self = shift;
        bless { _count => $self->{_run_fields_count} // 0 }, 'Test::MockRunFields';
    }
    sub pinned           { $_[0]->{pinned} }
    sub passed           { $_[0]->{passed} }
    sub failed           { $_[0]->{failed} }
    sub retried          { $_[0]->{retried} }
    sub concurrency_j    { $_[0]->{concurrency_j} }
    sub concurrency_x    { $_[0]->{concurrency_x} }
}
{
    package Test::MockRunFields;
    sub count { $_[0]->{_count} }
}

isa_ok('App::Yath::Schema::Result::Run', ['App::Yath::Schema::ResultBase'], 'inherits from ResultBase');
can_ok('App::Yath::Schema::Result::Run', [qw/complete sig normalize_to_mode/], 'has overlay methods');

subtest 'complete()' => sub {
    for my $status (qw/complete failed canceled broken/) {
        my $run = Test::MockRun->new({status => $status});
        ok($run->complete, "$status is a complete status");
    }
    for my $status (qw/pending running/) {
        my $run = Test::MockRun->new({status => $status});
        ok(!$run->complete, "$status is not a complete status");
    }
};

subtest 'sig()' => sub {
    my $run = Test::MockRun->new({
        status        => 'complete',
        pinned        => 0,
        passed        => 10,
        failed        => 0,
        retried       => 0,
        concurrency_j => 4,
        concurrency_x => 1,
        parameters    => undef,
        _run_fields_count => 2,
    });

    my $sig = $run->sig;
    ok(defined $sig, "sig returns a value");
    like($sig, qr/complete/, "sig contains status");
    like($sig, qr/;/, "sig uses semicolons as separator");

    # Same data produces same signature
    my $run2 = Test::MockRun->new({
        status        => 'complete',
        pinned        => 0,
        passed        => 10,
        failed        => 0,
        retried       => 0,
        concurrency_j => 4,
        concurrency_x => 1,
        parameters    => undef,
        _run_fields_count => 2,
    });
    is($run->sig, $run2->sig, "identical runs produce identical signatures");

    # Different data produces different signature
    my $run3 = Test::MockRun->new({
        status        => 'failed',
        pinned        => 0,
        passed        => 9,
        failed        => 1,
        retried       => 0,
        concurrency_j => 4,
        concurrency_x => 1,
        parameters    => undef,
        _run_fields_count => 2,
    });
    isnt($run->sig, $run3->sig, "different runs produce different signatures");
};

done_testing;
