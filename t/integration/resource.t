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

        is(
            $msgs{"yath-nested-runner"},
            {
                1 => [
                    'Record',
                    'Release',
                    'Record',
                    'Release',
                    'RESOURCE CLEANUP',
                ],
                2 => [
                    'Record',
                    'Release',
                    'Record',
                    'Release',
                    'RESOURCE CLEANUP',
                ],
            },
            "The nested runner saw the records and releases, and then cleaned up at the end."
        );

        is(
            $msgs{'yath-nested-scheduler'},
            {
                1 => [
                    'Assigned',
                    'Record',
                    'No Slots',
                    'Release',
                    'Assigned',
                    'Record',
                    'Release',
                ],
                2 => [
                    'Assigned',
                    'Record',
                    'No Slots',
                    'Release',
                    'Assigned',
                    'Record',
                    'Release',
                ],
            },
            "The scheduler handled assigning slots, knew when it was out, then knew when more were ready",
        );
    },
);

done_testing;

1;
