use utf8;
use Test2::V0;
use Test2::Plugin::UTF8;
use Test2::API qw/test2_stack/;
use Test2::Harness::Util::JSON qw/decode_json/;

test2_stack()->top;
my ($hub) = test2_stack()->all();
my $fmt = $hub->format;
skip_all "This test requires the stream formatter"
    unless $fmt && $fmt->isa('Test2::Formatter::Stream');

ok(1, "І ще трохи");

open(my $fh, '<:utf8', $fmt->file) or die "Could not open events file: $!";

my @lines = <$fh>;

like($lines[-1], qr/\QІ ще трохи\E/, "Wrote utf8, not double encoded");

done_testing;
