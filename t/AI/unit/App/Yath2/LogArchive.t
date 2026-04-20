use Test2::V0;

use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempdir/;

use App::Yath2::LogArchive;

# Build a fixture logdir under a tempdir: a mock "workdir/logs/" tree
# with a couple of run + service files so the archive path has real
# content to carry.
sub make_fixture_logdir {
    my $wd   = tempdir(CLEANUP => 1);
    my $logs = File::Spec->catdir($wd, 'logs');
    make_path("$logs/services");
    make_path("$logs/runs/AAAA/BBBB");

    for my $path (
        "$logs/services/harness.jsonl",
        "$logs/runs/AAAA/run.jsonl",
        "$logs/runs/AAAA/BBBB/0.jsonl",
        "$logs/runs/AAAA/BBBB/0.json",
        )
    {
        open(my $fh, '>', $path) or die "open $path: $!";
        print $fh "{\"file\":\"$path\"}\n";
        close($fh);
    }

    return $logs;
}

subtest 'supported_formats includes tar.gz by default' => sub {
    my @fmts = App::Yath2::LogArchive->supported_formats;
    my %have = map { $_ => 1 } @fmts;

    ok($have{'tar.gz'}, 'tar.gz is supported (core dep path)');

    ok(
        App::Yath2::LogArchive->format_is_supported('tar.gz'),
        'format_is_supported returns true for tar.gz'
    );

    ok(
        !App::Yath2::LogArchive->format_is_supported('nonsense'),
        'format_is_supported returns false for a bogus name'
    );
};

subtest 'create + extract round-trip (tar.gz)' => sub {
    skip_all "tar.gz backend not available"
        unless App::Yath2::LogArchive->format_is_supported('tar.gz');

    my $logs = make_fixture_logdir();
    my $dest = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dest, 'round.tar.gz');

    my $out = App::Yath2::LogArchive->create(
        logdir  => $logs,
        archive => $path,
    );
    is($out, $path, 'create returns the archive path');
    ok(-f $path, 'archive file exists after create');
    ok(-s $path, 'archive file is non-empty');

    my $extracted = App::Yath2::LogArchive->extract(archive => $path);

    for my $rel (qw{
        logs/services/harness.jsonl
        logs/runs/AAAA/run.jsonl
        logs/runs/AAAA/BBBB/0.jsonl
        logs/runs/AAAA/BBBB/0.json
    })
    {
        ok(
            -f File::Spec->catfile($extracted, $rel),
            "extracted: $rel"
        );
    }
};

subtest 'create refuses missing logdir' => sub {
    skip_all "tar.gz backend not available"
        unless App::Yath2::LogArchive->format_is_supported('tar.gz');

    my $dest = tempdir(CLEANUP => 1);
    like(
        dies {
            App::Yath2::LogArchive->create(
                logdir  => '/no/such/dir/plz',
                archive => "$dest/x.tar.gz",
            );
        },
        qr/does not exist/,
        'missing logdir is a clear error',
    );
};

subtest 'create refuses unknown format' => sub {
    my $dest = tempdir(CLEANUP => 1);
    like(
        dies {
            App::Yath2::LogArchive->create(
                logdir  => $dest,
                archive => "$dest/x.fake",
                format  => 'fake',
            );
        },
        qr/unsupported archive format/,
        'unknown format is rejected',
    );
};

subtest 'extract refuses missing archive' => sub {
    skip_all "tar.gz backend not available"
        unless App::Yath2::LogArchive->format_is_supported('tar.gz');

    like(
        dies {
            App::Yath2::LogArchive->extract(
                archive => '/no/such/archive.tar.gz',
            );
        },
        qr/does not exist/,
        'missing archive is a clear error',
    );
};

subtest 'inferred format via extension' => sub {
    skip_all "tar.gz backend not available"
        unless App::Yath2::LogArchive->format_is_supported('tar.gz');

    my $logs = make_fixture_logdir();
    my $dest = tempdir(CLEANUP => 1);

    # Just verify that .tgz also works (alternative tar.gz extension).
    my $path = File::Spec->catfile($dest, 'abc.tgz');
    App::Yath2::LogArchive->create(logdir => $logs, archive => $path);
    ok(-f $path, '.tgz archive produced');
};

done_testing;
