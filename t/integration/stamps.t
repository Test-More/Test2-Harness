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
    args    => [$dir, '--ext=tx', '-A', '--no-plugins', '-pTestPlugin', '-v'],
    exit    => T(),
    log     => 1,
    test    => sub {
        my $out = shift;

        while (my @events = $out->{log}->poll()) {
            for my $event (@events) {
                last unless $event;
                ok($event->{stamp}, "Event had a timestamp");
            }
        }
    },
);

done_testing;
