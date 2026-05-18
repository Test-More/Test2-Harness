use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();
use Cpanel::JSON::XS qw/encode_json/;
use Cwd qw/abs_path/;

# Integration coverage for the `yath render` command's CLI-as-wire-format
# contract. The renderer spawn path treats argv as the only serialisation
# surface between parent and child, so we exercise the corner cases that
# the codex review called out:
#
#   * spaces and shell metacharacters in LOGPATH
#   * empty-string values for flat options
#   * repeated options (last-wins semantics)
#   * very long combined option sets
#
# Each scenario invokes the installed `yath` binary against this checkout
# so the wrapper's argv splitting, the command dispatcher, and the
# renderer Loop are all exercised end-to-end.

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

# Resolve the worktree's lib relative to this test file. -D points the
# wrapper at this checkout's code instead of the installed dist.
my $libdir;
{
    my $test_file = abs_path(__FILE__);
    my ($vol, $dirs, undef) = File::Spec->splitpath($test_file);
    # .../t/AI/integration/Command/render_escaping.t -> .../lib
    my @parts = File::Spec->splitdir($dirs);
    pop @parts while @parts && $parts[-1] eq '';    # drop trailing empty
    splice @parts, -4;                              # drop t/AI/integration/Command
    push @parts, 'lib';
    $libdir = File::Spec->catpath($vol, File::Spec->catdir(@parts), '');
}

sub _yath_render {
    my ($args, %opts) = @_;
    my @cmd    = ($yath, "-D=$libdir", 'render', @$args);
    my $stdout = `@{[map { _shell_quote($_) } @cmd]} 2>&1`;
    my $exit   = $? >> 8;
    return ($stdout, $exit);
}

sub _shell_quote {
    my ($arg) = @_;
    # Single-quote the arg for shell, escaping any inner single quote.
    $arg =~ s/'/'\\''/g;
    return "'$arg'";
}

# Build a tiny sealed log on disk that our renderer invocations can
# point at. The simplest possible shape: one run, one job, one pass.
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
}

# --- spaces in LOGPATH ----------------------------------------------------

{
    my $base = tempdir(CLEANUP => 1);
    my $log  = "$base/log with spaces";
    make_path($log);
    _build_sealed_log($log);

    my ($out, $exit) = _yath_render(['terminal', $log]);
    is($exit, 0, 'spaces-in-LOGPATH: exit 0');
    like($out, qr/run\b.*PASSED/, 'spaces-in-LOGPATH: run summary rendered');
}

# --- shell metacharacters in LOGPATH (parens, dollars, semicolons) -------

{
    my $base = tempdir(CLEANUP => 1);
    my $log  = "$base/weird name \$ ; & ( ) [].log";
    make_path($log);
    _build_sealed_log($log);

    my ($out, $exit) = _yath_render(['terminal', $log]);
    is($exit, 0, 'metachars-in-LOGPATH: exit 0');
    like($out, qr/run\b.*PASSED/, 'metachars-in-LOGPATH: run summary rendered');
}

# --- empty-string value for a flat option --------------------------------

{
    my $base = tempdir(CLEANUP => 1);
    _build_sealed_log($base);

    # --junit-out '' should surface as a clean validation error (the
    # JUnit renderer requires a non-empty path). The empty string MUST
    # survive argv passthrough as an actual empty string rather than
    # being silently dropped or treated as a missing argument.
    my ($out, $exit) = _yath_render(['junit', $base, '--junit-out', '']);
    isnt($exit, 0, 'empty-string --junit-out surfaces non-zero exit (validation rejects)');
    like(
        $out,
        qr/requires.*output|junit/i,
        'empty-string --junit-out triggers JUnit start-time validation',
    );
}

# --- repeated options: last-wins for scalar settings ---------------------

{
    my $base = tempdir(CLEANUP => 1);
    _build_sealed_log($base);

    my $out1 = "$base/first.xml";
    my $out2 = "$base/second.xml";

    my ($stdout, $exit) = _yath_render(['junit', $base, '--junit-out', $out1, '--junit-out', $out2]);
    is($exit, 0, 'repeated --junit-out: exit 0');
    ok(-e $out2,  'last --junit-out value wins (second.xml exists)');
    ok(!-e $out1, 'first --junit-out value did not write');
}

# --- very long combined option sets -------------------------------------

{
    my $base = tempdir(CLEANUP => 1);
    _build_sealed_log($base);

    # Filesystem path component limits (NAME_MAX ~= 255 on Linux) cap
    # how long a single file/dir name can be, but argv has no such
    # ceiling short of ARG_MAX. To exercise a "very long option set"
    # without tripping NAME_MAX, build a deep nested directory tree
    # whose total path is well over 1000 chars and write the JUnit
    # XML there.
    my $deep = $base;
    for (1 .. 13) {
        my $segment = 'segment' . ('_' x 80);
        $deep = File::Spec->catdir($deep, $segment);
        make_path($deep);
    }
    my $out_path = File::Spec->catfile($deep, 'result.xml');

    cmp_ok(length($out_path), '>', 1000, 'output path is comfortably over 1000 chars');

    my ($stdout, $exit) = _yath_render(['junit', $base, '--junit-out', $out_path]);
    is($exit, 0, 'long option set: exit 0');
    ok(-e $out_path, 'long --junit-out path survived argv passthrough and was written');
}

done_testing;
