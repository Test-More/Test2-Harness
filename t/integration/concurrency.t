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
    args    => [$dir, '--ext=tx', '-j4'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $log = $out->{log};

        my @order;
        my @events = $log->poll();
        while (@events) {
            if (my $event = shift @events) {
                my $f = $event->{facet_data};

                if (my $e = $f->{harness_job_exit}) {
                    push @order => [exit => $e->{stamp}];
                }

                if (my $l = $f->{harness_job_start}) {
                    push @order => [start => $l->{stamp}];
                }
            }

            # Check for additional events, probably should not have any, but we may hit
            # a buffering limit in the log reader and need additional polls.
            push @events => $log->poll;
        }

# We care about the order in which events happened based on time stamp, not the
# order in which they were collected, which may be different. Here we will sort
# based on stamp.
        @order = map { $_->[0] } sort { $a->[1] <=> $b->[1] } @order;

# The first 4 events should be starts since we have 4 concurrent jobs
# After they start we MUST see an exit before any more can start
# Because of IPC timing we cannot be sure of the order of anything else, but we
# should have 1 more start and 4 more exits in any order.
        like(shift @order, qr/start/, "Item $_ is 'start'") for 0 .. 3;
        like(shift @order, qr/exit/, "Item 4 must be an exit");
        like(
            \@order,
            bag {
                item qr/start/;
                item qr/exit/ for 1 .. 4;
                end;
            },
            "Got one more start, and 4 more exits"
        );
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $log = $out->{log};

        my @order;
        my @events = $log->poll();
        while (@events) {
            if (my $event = shift @events) {
                my $f = $event->{facet_data};

                if (my $e = $f->{harness_job_exit}) {
                    push @order => [exit => $e->{stamp}];
                }

                if (my $l = $f->{harness_job_start}) {
                    push @order => [start => $l->{stamp}];
                }
            }

            # Check for additional events, probably should not have any, but we may hit
            # a buffering limit in the log reader and need additional polls.
            push @events => $log->poll;
        }

# We care about the order in which events happened based on time stamp, not the
# order in which they were collected, which may be different. Here we will sort
# based on stamp.
        @order = map { $_->[0] } sort { $a->[1] <=> $b->[1] } @order;

# The first 2 events should be starts since we have 2 concurrent jobs
# After they start we MUST see an exit before any more can start.
# Following that we should either see a start, or, if we want to be generous
# and assume the first 2 tests happened to finish at approx. the same time,
# then another exit followed by 2 starts.
        like(shift @order, qr/start/, "Item $_ is 'start'") for 0 .. 1;
        like(shift @order, qr/exit/, "Item 2 must be an exit");
        my $next = shift @order;
        if ($next =~ /exit/) {
            like(shift @order, qr/start/, "Item 4 must be a start if 3 was exit");
            like(shift @order, qr/start/, "Item 5 must be a start if 3 was exit");
        } else {
            like($next, qr/start/, "Item 3 must be a start");
        }
    },
);

done_testing;
