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
    pre     => ['-p+SmokePlugin'],
    args    => [$dir, '--ext=tx'],
    log     => 1,
    exit    => 0,
    test    => \&the_test,
);

yath(
    command => 'test',
    pre     => ['-p+SmokePlugin'],
    args    => [$dir, '-j3', '--ext=tx'],
    log     => 1,
    exit    => 0,
    test    => \&the_test,
);

sub the_test {
    my $out = shift;
    my $log = $out->{log};

    my @order;
    my @events = $log->poll();
    while (@events) {
        if (my $event = shift @events) {
            my $f = $event->{facet_data};

            if (my $l = $f->{harness_job_start}) {
                push @order => $l;
            }
        }

        # Check for additional events, probably should not have any, but we may hit
        # a buffering limit in the log reader and need additional polls.
        push @events => $log->poll;
    }

    # We care about the order in which events happened based on time stamp, not the
    # order in which they were collected, which may be different. Here we will sort
    # based on stamp.
    @order = sort { $a->{stamp} <=> $b->{stamp} } @order;

    is(
        [map { $_->{rel_file} } @order[0 .. 3]],
        bag {
            item match qr/a\.tx$/;
            item match qr/c\.tx$/;
            item match qr/e\.tx$/;
            item match qr/g\.tx$/;
            end;
        },
        "The 4 smoke tests ran first"
    );

    is(
        [map { $_->{rel_file} } @order[4 .. 7]],
        bag {
            item match qr/b\.tx$/;
            item match qr/d\.tx$/;
            item match qr/f\.tx$/;
            item match qr/h\.tx$/;
            end;
        },
        "The 4 non-smoke tests ran later"
    );
}

done_testing;
