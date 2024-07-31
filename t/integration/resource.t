use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

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
                next unless uc($i->{tag}) eq 'STDERR';
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
            $msgs{"yath-instance"},
            {
                1 => [
                    'Assigned',
                    'No Slots',
                    'Release',
                    'Assigned',
                    'Release',
                    'RESOURCE CLEANUP',
                    'RESOURCE CLEANUP',
                ],
                2 => [
                    'Assigned',
                    'No Slots',
                    'Release',
                    'Assigned',
                    'Release',
                    'RESOURCE CLEANUP',
                    'RESOURCE CLEANUP',
                ],
            },
            "The yath instance saw all the necessary messages"
        );
    },
);

done_testing;

1;
