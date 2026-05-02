use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();

use App::Yath2::LogArchive;
use App::Yath2::Command::archive;
use App::Yath2::Command::extract;
use Test2::Harness2::Util::Zstd qw/compress_blob compress_file_atomic/;

# Build a small logdir-shaped tree with a .json.zst artifact and a
# .jsonl.zst event stream. Loggers are now classified by file
# extension at read time, so no on-disk manifest is needed.
sub _make_logdir {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/services/harness");

    # A compressed snapshot.
    compress_file_atomic(
        "$dir/services/harness/state.json.zst",
        qq[{"kind":"harness","run_id":"R"}],
    );

    # A jsonl stream: two frames each compressed standalone.
    my $event = compress_blob(qq[{"event":"a"}\n]);
    open my $fh, '>', "$dir/services/harness/events.jsonl.zst" or die $!;
    binmode $fh;
    print $fh $event x 2;
    close $fh;

    return $dir;
}

{
    package Fake::Yath;
    sub new              { bless { cwd => $_[1] // '/tmp/no-such-cwd' }, $_[0] }
    sub cwd              { $_[0]->{cwd} }
    sub project          { '__UNKNOWN__' }
    sub user             { 'fakeuser' }
    sub user_config_file { '' }
    sub config_file      { '' }

    package Fake::Extract;
    sub new           { bless { no_decompress => $_[1] // 0 }, $_[0] }
    sub no_decompress { $_[0]->{no_decompress} }

    package Fake::Settings;
    sub new {
        my ($class, %p) = @_;
        bless {
            yath    => Fake::Yath->new($p{cwd}),
            extract => Fake::Extract->new($p{no_decompress} // 0),
        }, $class;
    }
    sub yath    { $_[0]->{yath} }
    sub extract { $_[0]->{extract} }
}

sub _run_cmd {
    my ($class, @args) = @_;
    my %extras;
    @args = grep { !(ref($_) eq 'HASH' and %extras = (%extras, %$_)) } @args;
    my $cmd  = $class->new(args => [@args], settings => Fake::Settings->new(%extras));
    my $out  = '';
    my $orig = select;
    open(my $cap, '>', \$out) or die $!;
    select $cap;
    my $rc  = eval { $cmd->run };
    my $err = $@;
    select $orig;
    close $cap;
    return ($rc, $out, $err);
}

subtest 'archive + extract (default decompresses)' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my (undef, undef, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');

    my $dest = "$work/restored";
    (undef, undef, $err) = _run_cmd('App::Yath2::Command::extract', $arc, $dest);
    is($err, '', 'extract: no exception');

    # .zst suffix stripped from output
    ok(-f "$dest/services/harness/state.json",   'json snapshot extracted plaintext');
    ok(-f "$dest/services/harness/events.jsonl", 'jsonl stream extracted plaintext');
    ok(!-f "$dest/services/harness/state.json.zst",
        'no .zst suffix on output');

    # Plaintext content is human-readable
    open my $rfh, '<', "$dest/services/harness/state.json" or die $!;
    my $body = do { local $/; <$rfh> };
    close $rfh;
    like($body, qr/"kind":"harness"/, 'json content readable');

    # The extracted tree is itself a valid Directory-shape archive
    # (yath replay /tmp/extracted/ should work). Loggers are now
    # resolved by extension at read time -- no manifest required.
    my $la = App::Yath2::LogArchive->open(path => $dest);
    is(
        $la->artifacts,
        {
            append  => { 'services/harness/events' => ['services/harness/events.jsonl'] },
            replace => { 'services/harness/state'  => ['services/harness/state.json']   },
        },
        'LogArchive::Directory reads the extracted tree (append/replace shape)',
    );
};

subtest 'archive + extract --no-decompress preserves .zst' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my (undef, undef, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');

    my $dest = "$work/restored_raw";
    (undef, undef, $err) = _run_cmd('App::Yath2::Command::extract', {no_decompress => 1}, $arc, $dest);
    is($err, '', 'extract: no exception');

    ok(-f "$dest/services/harness/state.json.zst",   'json.zst preserved');
    ok(-f "$dest/services/harness/events.jsonl.zst", 'jsonl.zst preserved');
    ok(!-f "$dest/services/harness/state.json",
        'no plaintext json when --no-decompress');
};

done_testing;
