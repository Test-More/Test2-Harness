# HARNESS-CONFLICTS YATH
use Test2::V0;
plan skip_all => "TODO: test uses \$log->poll() (JSONL API) but log=>1 now returns a workdir; needs rewrite to App::Yath2::LogArchive; also --no-plugins flag not yet implemented";
__END__

use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util::JSON qw/decode_json/;
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
