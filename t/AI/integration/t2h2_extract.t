use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# The t2h2_extract script reads a collector events file -- either plain jsonl or
# a multi-frame zstd file, detected from the leading bytes rather than the name
# -- and prints every event as one pretty-printed JSON array.

my $script = 'scripts/t2h2_extract';

# Returns ($exit_code, $stdout).
sub run_script ($file) {
    my $out = qx{$^X -Ilib \Q$script\E \Q$file\E};
    return ($? >> 8, $out);
}

subtest script_present => sub {
    ok(-f $script, "t2h2_extract script exists");
    ok(-x $script, "t2h2_extract script is executable");
};

subtest plain_jsonl => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/events.jsonl";    # plain, despite any name
    open(my $fh, '>', $file) or die "open: $!";
    print $fh qq[{"facet_data":{"info":[{"tag":"NOTE","details":"one"}]}}\n];
    print $fh qq[{"facet_data":{"info":[{"tag":"NOTE","details":"two"}]}}\n];
    close($fh);

    my ($code, $out) = run_script($file);
    is($code, 0, "exits 0 on a plain jsonl file");

    my $events = decode_json($out);
    is(ref($events), 'ARRAY', "output is a JSON array");
    is(scalar(@$events), 2, "both events extracted");
    is($events->[0]{facet_data}{info}[0]{details}, "one", "first event intact");
    is($events->[1]{facet_data}{info}[0]{details}, "two", "second event intact");

    like($out, qr/\n\s+"facet_data"/, "output is pretty-printed (multi-line, indented)");
};

subtest zstd_file => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/events.bin";      # zstd content, non-.zst name

    my $w = open_zstd_writer($file);
    $w->print(qq[{"facet_data":{"assert":{"pass":1,"details":"a"}}}], "\n");
    $w->print(qq[{"facet_data":{"assert":{"pass":1,"details":"b"}}}], "\n");
    $w->close;

    my ($code, $out) = run_script($file);
    is($code, 0, "exits 0 on a zstd file detected by content");

    my $events = decode_json($out);
    is(scalar(@$events), 2, "both events extracted from the zstd file");
    is($events->[0]{facet_data}{assert}{details}, "a", "first frame decoded");
    is($events->[1]{facet_data}{assert}{details}, "b", "second frame decoded");
};

subtest usage_error => sub {
    system($^X, '-Ilib', $script);
    isnt($? >> 8, 0, "missing argument is an error");
};

done_testing;
