use v5.38;
use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness2::Collector;

{
    package Fake::Row;
    use v5.38;
    sub new ($class) { bless { data => {} }, $class }
    sub update ($self, $changes) { %{$self->{data}} = (%{$self->{data}}, %$changes); $self }
    sub field  ($self, $col, @set) { $self->{data}{$col} = $set[0] if @set; $self->{data}{$col} }
}

my $dir = tempdir(CLEANUP => 1);
my $events = "$dir/events.jsonl.zst";

my $crow = Fake::Row->new;
my $arow = Fake::Row->new;

my $exit = Test2::Harness2::Collector->start(
    is_test       => 0,
    events_file   => $events,
    exec_command  => [$^X, '-e', 'print "hi\n"; exit 0'],
    collector_row => $crow,
    artifact_row  => $arow,
);

is($exit, 0, "collector finished cleanly");
ok(defined $crow->field('child_pid'), "collector recorded child_pid on its row");
ok(defined $crow->field('stopped'),   "collector recorded stopped time");
is($crow->field('exit_code'), 0,      "collector recorded its own exit code 0");
ok(defined $arow->field('data'),      "collector populated artifact data blob from events file");
ok(length($arow->field('data')) > 0,  "events data is non-empty");

done_testing;
