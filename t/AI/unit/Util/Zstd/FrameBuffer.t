use Test2::V0;
use v5.38;

use Compress::Zstd qw/compress/;
use Test2::Harness2::Util::Zstd::FrameBuffer;

sub fb () { Test2::Harness2::Util::Zstd::FrameBuffer->new }

subtest one_frame_one_drain => sub {
    my $b = fb();
    $b->push_bytes(compress("hello"));
    my @got = $b->drain;
    is(scalar(@got), 1, "one frame");
    is($got[0]{payload}, "hello", "decoded payload");
    is($got[0]{frame}, compress("hello"), "raw frame bytes retained verbatim");
};

subtest multiple_frames_concatenated => sub {
    my $b = fb();
    $b->push_bytes(compress("a") . compress("bb") . compress("ccc"));
    my @got = $b->drain;
    is([map { $_->{payload} } @got], ["a", "bb", "ccc"], "splits all frames in order");
};

subtest partial_frame_waits => sub {
    my $b     = fb();
    my $frame = compress("partial-data-here");
    $b->push_bytes(substr($frame, 0, 3));         # incomplete header
    is([$b->drain], [], "no complete frame yet");
    $b->push_bytes(substr($frame, 3));            # rest arrives
    my @got = $b->drain;
    is(scalar(@got), 1, "frame completes once all bytes arrive");
    is($got[0]{payload}, "partial-data-here", "reassembled payload");
};

subtest next_frame_one_at_a_time => sub {
    my $b = fb();
    $b->push_bytes(compress("x") . compress("y"));
    my $f1 = $b->next_frame;
    is($f1->{payload}, "x", "next_frame returns first");
    my $f2 = $b->next_frame;
    is($f2->{payload}, "y", "next_frame returns second");
    is($b->next_frame, undef, "undef when no complete frame remains");
};

subtest bad_frame_croaks => sub {
    my $b = fb();
    # A complete-looking frame whose body is corrupt: build a valid frame, flip body bytes.
    my $frame = compress("real");
    substr($frame, 5, 1) = chr((ord(substr($frame, 5, 1)) ^ 0xFF));
    $b->push_bytes($frame);
    my $err = dies { $b->drain };
    like($err, qr/decompress/i, "corrupt frame body croaks on decode");
};

done_testing;
