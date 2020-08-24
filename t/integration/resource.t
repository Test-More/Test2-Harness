use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j4', "-D$dir", '-R+Resource'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $log = $out->{log};

        my @events = $log->poll();

        my @msgs;
        for my $event (@events) {
            my $f = $event->{facet_data};
            my $info = $f->{info} or next;
            for my $i (@$info) {
                next unless $i->{tag} eq 'INTERNAL';
                push @msgs => $i->{details};
            }
        }

        is(pop @msgs, "RESOURCE CLEANUP", "Cleaned up resources at the end");

        like(
            [splice(@msgs, 0, 5)],
            [
                qr/Assigned: \S+ - 1/,
                qr/Record: \S+ - 1/,
                qr/Assigned: \S+ - 2/,
                qr/Record: \S+ - 2/,
                "No Slots",
            ],
            "Assigned both slots, then ran out of slots"
        );

        my (@id1, @id2);
        for my $msg (@msgs) {
            $msg =~ m/- ([12])$/;
            my $into = $1 eq '1' ? \@id1 : \@id2;
            push @$into => $msg;
        }

        my $id = 0;
        for my $set (\@id1, \@id2) {
            $id++;

            like(
                shift @$set,
                qr/Release: \S+ - $id$/,
                "Released the resource $id"
            );

            my ($job) = ($set->[0] =~ m/\S+: (\S+) - $id$/);
            like(
                $set,
                [
                    qr/Assigned: $job - $id$/,
                    qr/Record: $job - $id$/,
                    qr/Release: $job - $id$/,
                ],
                "Full Cycle $id"
            );
        }
    },
);

done_testing;

1;
