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

my $out1 = yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v', '--event-timeout' => 2],
    log     => 1,
    exit    => T(),
    test    => sub {
        my $out = shift;

        like($out->{output}, qr/\+ outer 1/, "See outermost events");
        like($out->{output}, qr/> \+ inner 1/, "See inner events");
        like($out->{output}, qr/> > \+ deeper 1/, "See deeper event");
        like($out->{output}, qr/> > > \+ even deeper 1/, "See deepest events");
        like($out->{output}, qr/> > > > diag/, "See last event");
    },
);

done_testing;
