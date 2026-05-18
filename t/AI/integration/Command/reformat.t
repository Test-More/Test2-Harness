use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();
use Cwd qw/abs_path/;
use Cpanel::JSON::XS qw/encode_json/;

use Test2::Harness2::Util::JSON qw/decode_json/;

# Integration coverage for `yath reformat`:
#
#   * in-place rewrite against a Directory log builds the events.txt
#     formatter artifact and updates meta.json's formatter-versions.
#   * second invocation is a no-op (existing-file-wins on the artifact;
#     meta.json simply re-asserts the same version).
#   * read-only log without an OUTLOG argument is a clear error.
#   * passing OUTLOG materialises a refreshed copy.

sub _find_yath {
    for my $p (split /:/, ($ENV{PATH} // '')) {
        my $cand = "$p/yath";
        return $cand if -x $cand;
    }
    return;
}

my $yath = _find_yath();
skip_all "yath binary not on PATH"
    unless defined $yath && -x $yath;

my $libdir;
{
    my $test_file = abs_path(__FILE__);
    my ($vol, $dirs, undef) = File::Spec->splitpath($test_file);
    my @parts = File::Spec->splitdir($dirs);
    pop @parts while @parts && $parts[-1] eq '';
    splice @parts, -4;
    push @parts, 'lib';
    $libdir = File::Spec->catpath($vol, File::Spec->catdir(@parts), '');
}

sub _yath {
    my @args   = @_;
    my @cmd    = ($yath, "-D=$libdir", @args);
    my $stdout = `@{[map { _shell_quote($_) } @cmd]} 2>&1`;
    my $exit   = $? >> 8;
    return ($stdout, $exit);
}

sub _shell_quote {
    my ($arg) = @_;
    $arg =~ s/'/'\\''/g;
    return "'$arg'";
}

sub _build_sealed_log {
    my ($root) = @_;
    make_path("$root/runs/1/jobs/1/0");

    open(my $efh, '>', "$root/runs/1/jobs/1/0/events.jsonl") or die "events: $!";
    print $efh encode_json({facet_data => {assert => {pass  => 1, details => 'ok 1'}}}) . "\n";
    print $efh encode_json({facet_data => {plan   => {count => 1}}}) . "\n";
    close $efh;

    open(my $rfh, '>', "$root/runs/1/jobs/1/0/report.jsonl") or die "report: $!";
    print $rfh encode_json({pass => 1}) . "\n";
    close $rfh;

    open(my $sfh, '>', "$root/runs/1/jobs/1/0/.sealed") or die "sealed job: $!";
    print $sfh encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
    close $sfh;

    open(my $rsfh, '>', "$root/runs/1/.sealed") or die "sealed run: $!";
    print $rsfh encode_json({sealed_at => 200, final_state => 'completed', pass => 1, exit => 0});
    close $rsfh;

    # Minimal meta.json so update_meta_formatters actually writes.
    open(my $mfh, '>', "$root/meta.json") or die "meta: $!";
    print $mfh encode_json({format_version => 1});
    close $mfh;
}

# --- in-place reformat against a directory log ----------------------------

{
    my $log = tempdir(CLEANUP => 1);
    _build_sealed_log($log);

    my ($out, $exit) = _yath('reformat', $log);
    is($exit, 0, 'in-place reformat: exit 0');
    ok(-e "$log/runs/1/jobs/1/0/events.txt", 'events.txt formatter artifact written');

    open(my $mfh, '<', "$log/meta.json") or die "open meta: $!";
    my $meta = decode_json(do { local $/; <$mfh> });
    close $mfh;
    is($meta->{format_version}, 1, 'format_version preserved');
    ok($meta->{formatters},              'formatters block written');
    ok(defined $meta->{formatters}{txt}, 'txt formatter version recorded');

    # Second invocation: existing-file-wins on the artifact; meta.json
    # simply re-asserts the same version. The command should still
    # succeed.
    my ($out2, $exit2) = _yath('reformat', $log);
    is($exit2, 0, 'second reformat: still exit 0 (idempotent)');
}

# --- read-only log without OUTLOG is a clear error -----------------------

{
    # Build a directory log, archive it to a .yath tarball, then try to
    # reformat the tarball in-place. Should error out and direct the
    # user at the OUTLOG form.
    my $srcdir = tempdir(CLEANUP => 1);
    _build_sealed_log($srcdir);

    my $tarball = tempdir(CLEANUP => 1) . '/archive.yath';

    # Use yath archive to produce the tarball; sidesteps poking at the
    # archive writer's private API from a test.
    my ($a_out, $a_exit) = _yath('archive', $srcdir, $tarball);
    is($a_exit, 0, 'yath archive built tarball for setup')
        or diag $a_out;

    my ($r_out, $r_exit) = _yath('reformat', $tarball);
    isnt($r_exit, 0, 'in-place reformat of tarball: non-zero exit');
    like(
        $r_out,
        qr/writable log|OUTLOG/i,
        'read-only log error mentions writable log or OUTLOG form',
    );
}

# --- OUTLOG form materialises a refreshed copy ---------------------------

{
    my $srcdir = tempdir(CLEANUP => 1);
    _build_sealed_log($srcdir);

    my $tarball = tempdir(CLEANUP => 1) . '/archive.yath';
    my ($a_out, $a_exit) = _yath('archive', $srcdir, $tarball);
    is($a_exit, 0, 'archive setup OK') or diag $a_out;

    my $outlog = tempdir(CLEANUP => 1) . '/refreshed';
    my ($r_out, $r_exit) = _yath('reformat', $tarball, $outlog);
    is($r_exit, 0, 'tarball + OUTLOG reformat: exit 0') or diag $r_out;
    ok(-d $outlog,                              'OUTLOG directory created');
    ok(-e "$outlog/runs/1/jobs/1/0/events.txt", 'events.txt written in OUTLOG');
    ok(-e $tarball,                             'original tarball still present');
}

done_testing;
