use utf8;
use strict;
use warnings;
use Test::More;
use Test2::Plugin::UTF8;
use Test2::API qw/test2_stack/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Tools::Basic qw/skip_all/;
use File::Spec;
use Test2::Util qw/get_tid ipc_separator/;
# HARNESS-DURATION-SHORT

print STDOUT "STDOUT: Mākaha\n";
note "NOTE: Mākaha";
ok(1, "ASSERT: Mākaha");

test2_stack()->top;
my ($hub) = test2_stack()->all();
my $fmt = $hub->format;
skip_all "This test requires the stream formatter"
    unless $fmt && $fmt->isa('Test2::Formatter::Stream');

my $file = File::Spec->catfile($fmt->dir, join(ipc_separator() => 'events', $$, 0) . ".jsonl");
open(my $events_fh, '<:utf8', $file) or die "Could not open events file: $!";
open(my $stdout_fh, '<:utf8', File::Spec->catfile($ENV{TEST2_JOB_DIR}, 'stdout')) or die "Could not open STDOUT for reading: $!";

my @events = map { decode_json($_) } grep m/(NOTE|DIAG|ASSERT): /, <$events_fh>;
my ($stdout) = grep m/STDOUT: /, <$stdout_fh>;

is($stdout, "STDOUT: Mākaha\n", "Round trip STDOUT encoding/decoding");

is($events[0]->{facet_data}->{info}->[0]->{details}, "NOTE: Mākaha", "Round trip encoding/decoding a note");
is($events[1]->{facet_data}->{assert}->{details}, "ASSERT: Mākaha", "Round trip encoding/decoding an assert");

done_testing;
