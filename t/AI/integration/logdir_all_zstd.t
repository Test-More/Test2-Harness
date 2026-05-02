use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use File::Find ();

use Test2::Harness2;
use Test2::Harness2::Collector::Logger::JSON;
use Test2::Harness2::Collector::Logger::JSONL;

# Architectural enforcement test: every regular file the loggers /
# harness write under workdir/logs/ must end in .zst (zstd-loggers
# spec sec 12). Anything else means a producer wrote plaintext
# directly into the live logdir, which violates the
# all-text-files-zstd-compressed rule.
#
# Future producers landing new binary content types under $logdir
# (images, screenshots, etc.) get added to the binary-signature
# allowlist below.

my %BINARY_SIG = (
    'PNG'  => "\x89PNG\r\n\x1a\n",
    'JPEG' => "\xff\xd8\xff",
    'GIF'  => "GIF8",
    'WebM' => "\x1aE\xdf\xa3",
    'MP4-ftyp' => undef,    # checked separately: ftyp at byte offset 4
);

sub _looks_binary {
    my ($path) = @_;
    return 0 unless -f $path;
    open my $fh, '<', $path or return 0;
    binmode $fh;
    my $head;
    read($fh, $head, 16) // return 0;
    close $fh;

    for my $name (keys %BINARY_SIG) {
        my $sig = $BINARY_SIG{$name} // next;
        return 1 if substr($head, 0, length $sig) eq $sig;
    }

    # MP4 ftyp at offset 4: bytes 4-7 == "ftyp"
    return 1 if length($head) >= 8 && substr($head, 4, 4) eq 'ftyp';

    return 0;
}

sub _drive_harness {
    my $wd = tempdir(CLEANUP => 1);
    my $h = Test2::Harness2->new(
        workdir    => $wd,
        ipc_parent => 1,
    );

    # Construct one of each logger type and call its startup hook
    # so it actually creates a file under $logdir. Use explicit
    # output_file paths (the loggers' identity-based path
    # resolution requires running under a spawning collector,
    # which is more setup than this test needs).
    my $jsonl = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info   => {},
        logdir      => $h->logdir,
        output_file => $h->logdir . '/services/test/events.jsonl.zst',
    );
    $jsonl->prepare_output_locations;
    $jsonl->startup;
    $jsonl->shutdown;

    my $json = Test2::Harness2::Collector::Logger::JSON->new(
        ipcm_info   => {},
        logdir      => $h->logdir,
        output_file => $h->logdir . '/services/test/state.json.zst',
    );
    $json->prepare_output_locations;
    $json->startup;
    $json->shutdown;

    return $h->logdir;
}

sub _walk_assert {
    my ($logdir, $label) = @_;

    my @bad;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                my $rel = File::Spec->abs2rel($_, $logdir);
                return if $rel =~ /\.zst\z/;
                return if _looks_binary($_);
                push @bad => $rel;
            },
        },
        $logdir,
    );

    is(\@bad, [], "$label: every file under \$logdir is .zst or binary");
}

subtest 'logdir-all-zstd' => sub {
    my $logdir = _drive_harness();
    _walk_assert($logdir, 'all files');
};

done_testing;
