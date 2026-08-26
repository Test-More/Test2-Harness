use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j4', "-D$dir", '-R+Resource'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $log = $out->{log};

        my @events = $log->poll();

        my %pids;
        my %msgs;
        for my $event (@events) {
            my $f = $event->{facet_data};
            my $info = $f->{info} or next;
            for my $i (@$info) {
                next unless $i->{tag} eq 'INTERNAL';
                if ($i->{details} =~ m/^(\S+) - (yath-\S+)$/) {
                    $pids{$1} = $2;
                    next;
                }

                next unless $i->{details} =~ m/^(\S+) - (?:(\S+): \S+ - (\d)|(.+))$/;
                my ($pid, $action, $res_id) = ($1, ($2 || $4), $3);

                $pid = $pids{$pid} // $pid;

                if ($res_id) {
                    push @{$msgs{$pid}->{$res_id}} => $action;
                }
                else {
                    push @{$msgs{$pid}->{$_}} => $action for keys %{$msgs{$pid}};
                }
            }
        }

        # Which slot serves which test is up to timing: a machine where one
        # test finishes early lets its slot take the next two, and nothing is
        # wrong with that. What has to hold is that each slot is used and
        # freed in order, that all four tests went through, and that the
        # scheduler noticed when it ran out of slots.
        my $cycle = sub {
            my ($actions, @pattern) = @_;

            my $i = 0;
            for my $action (@$actions) {
                return "expected $pattern[$i], got $action" unless $action eq $pattern[$i];
                $i = ($i + 1) % @pattern;
            }

            return "ended mid-cycle, expected $pattern[$i]" if $i;
            return undef;
        };

        my $runner = $msgs{'yath-nested-runner'};
        is([sort keys %$runner], [1, 2], "The runner saw both slots");

        my %runner_counts;
        for my $slot (sort keys %$runner) {
            my @actions = @{$runner->{$slot}};

            is(pop(@actions), 'RESOURCE CLEANUP', "Slot $slot was cleaned up at the end of the run");
            $runner_counts{$_}++ for @actions;

            is($cycle->(\@actions, 'Record', 'Release'), undef, "Slot $slot was recorded and released in turn by the runner")
                or diag(join(', ' => @{$runner->{$slot}}));
        }

        is(\%runner_counts, {Record => 4, Release => 4}, "The runner ran all 4 tests");

        my $scheduler = $msgs{'yath-nested-scheduler'};
        is([sort keys %$scheduler], [1, 2], "The scheduler saw both slots");

        my %scheduler_counts;
        my $no_slots = 0;
        for my $slot (sort keys %$scheduler) {
            my @actions = grep { $_ ne 'No Slots' } @{$scheduler->{$slot}};

            $no_slots++ if @actions != @{$scheduler->{$slot}};
            $scheduler_counts{$_}++ for @actions;

            is($cycle->(\@actions, 'Assigned', 'Record', 'Release'), undef, "Slot $slot was assigned, recorded and released in turn")
                or diag(join(', ' => @{$scheduler->{$slot}}));
        }

        is(\%scheduler_counts, {Assigned => 4, Record => 4, Release => 4}, "The scheduler assigned all 4 tests");
        ok($no_slots, "The scheduler ran out of slots at some point");
    },
);

done_testing;

1;
