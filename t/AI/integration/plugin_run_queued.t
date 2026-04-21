use Test2::V0;
use File::Temp qw/tempdir/;
use Cpanel::JSON::XS qw/decode_json/;
use POSIX qw/_exit/;

use lib 't/lib';
use App::Yath2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers classic_test_loggers/;

use Test2::Harness2;

# Integration check: a plugin attached to Test2::Harness2 has its
# run_queued hook dispatched when a run enters the queue, and any
# returned fields land on the run's TO_JSON snapshot (and therefore
# on the run_queued service event).
#
# Uses an inline test plugin class so the test stays self-contained
# and doesn't depend on SysInfo/Git environmental quirks.

package TestHarness::Plugin::Stamper;
use strict;
use warnings;
use Role::Tiny::With;
with 'Test2::Harness2::Role::Plugin';

sub new {
    my ($class, %args) = @_;
    return bless {%args}, $class;
}

sub run_queued {
    my ($self, $run) = @_;
    return (
        {name => 'stamper', details => 'hello', raw => 'hi', data => {pid => $$}},
        {name => 'stamper2', details => 'second', raw => 'two', data => {n => 2}},
    );
}

package main;

my $dir = tempdir(CLEANUP => 1);

my $test_file = "$dir/ok.t";
open my $fh, '>', $test_file or die $!;
print $fh <<'EOF';
use Test2::V0;
ok(1, "trivial pass");
done_testing;
EOF
close $fh;

my $pid = fork // die $!;
if (!$pid) {
    Test2::Harness2->start(
        workdir                  => $dir,
        loggers                  => classic_harness_loggers($dir),
        test_loggers             => classic_test_loggers(),
        plugins                  => [TestHarness::Plugin::Stamper->new()],
        test_run                 => {files => [App::Yath2::TestFile->new(file => $test_file)]},
        finish_after_initial_run => 1,
    );
    POSIX::_exit(0);
}

waitpid $pid, 0;
my $exit = $? >> 8;
is($exit, 0, 'service exited cleanly');

# Read the service log and look for the run_queued event. Confirm
# the plugin-stamped fields landed in the run_data snapshot.
open my $slog, '<', "$dir/logs/services/harness.jsonl"
    or die "Cannot open harness.jsonl: $!";
my @events = map { decode_json($_) } grep { /\S/ } <$slog>;
close $slog;

my ($rq) = grep { ($_->{facet_data}{harness}{kind} // '') eq 'run_queued' } @events;
ok($rq, 'run_queued service event present');

my $run_data = $rq->{facet_data}{harness}{run_data};
ok($run_data, 'run_queued event carries run_data');

my $fields = $run_data->{fields};
ok(ref($fields) eq 'ARRAY', 'run_data.fields is an arrayref');
is(scalar(@$fields), 2, 'both plugin-supplied fields arrived');

my %by_name = map { $_->{name} => $_ } @$fields;
is($by_name{stamper}{details},  'hello',  'stamper details');
is($by_name{stamper2}{details}, 'second', 'stamper2 details');
is($by_name{stamper}{data}{pid}, $by_name{stamper}{data}{pid},
    'stamper data survived round-trip');

done_testing;
