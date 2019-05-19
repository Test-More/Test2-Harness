use utf8;
use Test2::V0;
use Test2::Plugin::UTF8;
use Test2::API qw/test2_stack/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Util qw/get_tid ipc_separator/;

test2_stack()->top;
my ($hub) = test2_stack()->all();
my $fmt = $hub->format;
skip_all "This test requires the stream formatter"
    unless $fmt && $fmt->isa('Test2::Formatter::Stream');

ok(1, "І ще трохи");

my $file = File::Spec->catfile($fmt->dir, join(ipc_separator() => 'events', $$, 0) . ".jsonl");
open(my $fh, '<:utf8', $file) or die "Could not open events file: $!";

my @lines = <$fh>;

like($lines[-1], qr/\QІ ще трохи\E/, "Wrote utf8, not double encoded");

done_testing;
