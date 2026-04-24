use Test2::V0 -target => 'Test2::Harness2::TestFile';
# HARNESS-DURATION-SHORT

use File::Temp qw/tempdir/;
use File::Spec();

use ok $CLASS;

# Derived from reference/legacy/t/unit/Test2/Harness/TestFile.t and
# rewritten for the Stages A-H TestFile rebuild. Legacy's assertions
# were largely driven through queue_item(42) and the rank/shbang
# methods, none of which exist in the new design (queue_item and
# rank belong to the scheduler, shbang's switches are exposed
# directly via $tf->switches). Fixture bodies are ported verbatim
# so the scanner sees the same real-world HARNESS-* combinations
# the legacy suite exercised; assertions are rewritten to go
# through check_feature / check_duration / check_category / direct
# accessors.

my $tdir = tempdir(CLEANUP => 1);

my %FIXTURES = (
    long   => "#!/usr/bin/perl\n\nuse strict;\n use warnings\n\n# HARNESS-CAT-LONG\n# HARNESS-NO-TIMEOUT\n# HARNESS-USE-ISOLATION\nfoo\n# HARNESS-NO-SEE\n",
    med1   => "# HARNESS-NO-PRELOAD\n",
    med2   => "#HARNESS-NO-FORK\n",
    all    => "#HARNESS-NO-TIMEOUT\n# HARNESS-NO-STREAM\n# HARNESS-NO-FORK\n# HARNESS-NO-PRELOAD\n# HARNESS-USE-ISOLATION\n",
    notime => "#HARNESS-NO-TIMEOUT\n",
    warn   => "#!/usr/bin/perl -w\n",
    taint  => "#!/usr/bin/env perl -t -w\n",
    foo    => "#HARNESS-CATEGORY-FOO\n#HARNESS-STAGE-FoO",
    meta   => "#HARNESS-META-mykey-myval\n# HARNESS-META-otherkey-otherval\n# HARNESS-META mykey my-val2\n# HARNESS-META slack #my-val # comment after harness statement\n",

    package => "package Foo::Bar::Baz;\n# HARNESS-NO-PRELOAD\n",

    timeout    => "# HARNESS-TIMEOUT-EVENT 90\n# HARNESS-TIMEOUT-POSTEXIT 85\n",
    timeout2   => "# HARNESS-TIMEOUT-EVENT-90\n# HARNESS-TIMEOUT-POST-EXIT   85\n",
    badtimeout => "# HARNESS-TIMEOUT-EVENTX 90\n# HARNESS-TIMEOUT-POSTEXITX 85\n",

    conflicts1 => "# HARNESS-CONFLICTS PASSWD\n",
    conflicts2 => "# HARNESS-CONFLICTS PASSWD DAEMON\n",
    conflicts3 => "# HARNESS-CONFLICTS PASSWD\n# HARNESS-CONFLICTS DAEMON   # Nothing to see here\n",
    conflicts4 => "# HARNESS-CONFLICTS PASSWD DAEMON\n# HARNESS-CONFLICTS PASSWD\n# HARNESS-CONFLICTS PASSWD\n# HARNESS-CONFLICTS PASSWD DAEMON\n",

    extra_comments => "#!/usr/bin/perl\n\nuse strict;\n# comment here\n use warnings\n\n# copyright Dewey Cheatem and Howe\n# HARNESS-CAT-LONG\n# HARNESS-NO-TIMEOUT\n# HARNESS-USE-ISOLATION\n",

    smoke1 => "#HARNESS-SMOKE\n",
    smoke2 => "#HARNESS-YES-SMOKE\n",

    retry      => "#HARNESS-RETRY\n",
    retry5     => "#HARNESS-RETRY 5\n",
    retry_iso  => "#HARNESS-RETRY-ISO\n",
    retry_iso3 => "#HARNESS-RETRY-ISO 3\n",
    no_retry   => "#HARNESS-NO-RETRY\n",

    not_perl     => "#!/usr/bin/bash\n",
    not_env_perl => "#!/usr/bin/env bash\n",

    # Legacy uses a short 6-byte binary header. The new parser's
    # -B _ && !-z _ guard requires -B to classify the file as
    # binary; on systems where 6 bytes is below -B's threshold we
    # fall through to the Perl-text scanning path. Use a longer
    # random body to make the detection deterministic.
);

# Materialise fixtures on disk.
for my $name (keys %FIXTURES) {
    my $path = File::Spec->catfile($tdir, $name);
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} $FIXTURES{$name};
    close($fh);
}

# Binary fixture: 512 random bytes so -B always classifies.
{
    my $path = File::Spec->catfile($tdir, 'binary');
    open(my $fh, '>', $path) or die "open $path: $!";
    binmode($fh);
    print {$fh} pack('C*', map { int rand 256 } 1 .. 512);
    close($fh);
}

sub tf_for {
    my $name = shift;
    my $tf   = $CLASS->new(file => File::Spec->catfile($tdir, $name));
    # Auto-scan so subtests may read raw accessors directly. Tests
    # that specifically exercise lazy-scan semantics should construct
    # the TestFile inline rather than going through tf_for.
    $tf->scan;
    return $tf;
}

subtest timeouts => sub {
    my $one = tf_for('timeout');
    is($one->event_timeout,     90, "set event timeout");
    is($one->post_exit_timeout, 85, "set postexit timeout");

    my $two = tf_for('timeout2');
    is($two->event_timeout,     90, "dash-delimited event timeout");
    is($two->post_exit_timeout, 85, "POST-EXIT collapses into postexit");

    # Construct directly (not via tf_for) so warnings { ... } captures
    # the scan emissions rather than letting tf_for's auto-scan leak
    # them to the top-level.
    my $bad = $CLASS->new(file => File::Spec->catfile($tdir, 'badtimeout'));
    is(
        warnings { $bad->scan },
        [
            "'EVENTX' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at " . $bad->file . " line 1.\n",
            "'POSTEXITX' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at " . $bad->file . " line 2.\n",
        ],
        "Got warnings for bad timeout types",
    );
};

subtest meta => sub {
    my $foo = tf_for('meta');

    is($foo->meta->{mykey},    [qw/myval my-val2/], "Got both values for the 'mykey' key");
    is($foo->meta->{otherkey}, ['otherval'],        "Got other key");
    is($foo->meta->{slack},    ['#my-val'],         "Trailing-comment strip preserves leading # in value");
};

subtest 'category + stage' => sub {
    my $foo = tf_for('foo');
    is($foo->check_category, 'foo', "Category is foo");
    is($foo->check_stage,    'FoO', "Stage is case-sensitive");
};

subtest 'package line before directives still allows scanning' => sub {
    my $one = tf_for('package');
    is($one->check_feature('preload'), 0, "Scanner walks past 'package ...;' to reach HARNESS-NO-PRELOAD");
};

subtest 'taint: -t -w forces fork and preload off' => sub {
    my $taint = tf_for('taint');
    is($taint->switches,                 ['-t', '-w'], "env perl -t -w switches parsed in order");
    is($taint->check_feature('fork'),    0,            "-t disables fork");
    is($taint->check_feature('preload'), 0,            "-t disables preload");
};

subtest 'warn: -w alone leaves fork and preload on' => sub {
    my $warn = tf_for('warn');
    is($warn->switches,                 ['-w'], "got shebang switches");
    is($warn->check_feature('fork'),    1,      "-w does not disable fork");
    is($warn->check_feature('preload'), 1,      "-w does not disable preload");
};

subtest 'notime: NO-TIMEOUT lifts duration to long' => sub {
    my $notime = tf_for('notime');
    is($notime->check_feature('timeout'),    0,         "Timeouts turned off");
    is($notime->check_feature('timeout', 1), 0,         "Timeouts off even with caller default 1");
    is($notime->check_category,              'general', "Category falls through to general");
    is($notime->check_duration,              'long',    "NO-TIMEOUT raises duration to long");
    is($notime->switches,                    [],        "No shebang switches");
};

subtest 'all: every scheduler-affecting feature toggled off' => sub {
    my $all = tf_for('all');

    is($all->check_feature('timeout'),   0, "Timeouts turned off");
    is($all->check_feature('fork'),      0, "Forking off");
    is($all->check_feature('preload'),   0, "Preload off");
    is($all->check_feature('stream'),    0, "Stream off");
    is($all->check_feature('isolation'), 1, "Isolation on");

    is($all->check_feature('timeout',   1), 0, "feature-set value wins over caller default");
    is($all->check_feature('fork',      0), 0, "fork stays off under safety override-free path");
    is($all->check_feature('isolation', 0), 1, "USE-ISOLATION wins over caller default 0");

    is($all->check_category, 'isolation', "USE-ISOLATION lifts category to isolation");
    is($all->check_duration, 'long',      "NO-TIMEOUT lifts duration to long");
};

subtest 'med1: NO-PRELOAD alone only turns preload off' => sub {
    my $med1 = tf_for('med1');
    is($med1->check_feature('preload'), 0,         "Preload off");
    is($med1->check_feature('fork'),    1,         "Fork stays on");
    is($med1->check_feature('timeout'), 1,         "Timeout stays on");
    is($med1->check_duration,           'medium',  "duration still medium");
    is($med1->check_category,           'general', "category still general");
};

subtest 'med2: NO-FORK alone only turns fork off' => sub {
    my $med2 = tf_for('med2');
    is($med2->check_feature('fork'),    0, "Fork off");
    is($med2->check_feature('preload'), 1, "Preload stays on");
};

subtest 'long: mixed CAT-LONG + NO-TIMEOUT + USE-ISOLATION; stop at "foo" line' => sub {
    my $long = tf_for('long');

    is($long->check_feature('timeout'),   0,           "NO-TIMEOUT honoured");
    is($long->check_feature('isolation'), 1,           "USE-ISOLATION honoured");
    is($long->check_category,             'isolation', "category derived from USE-ISOLATION");
    is($long->check_duration,             'long',      "CAT-LONG sets duration=long");

    # Locks in that the scanner stopped at the "foo\n" line and never
    # reached the "# HARNESS-NO-SEE" trailer, i.e. the last/next
    # stop-condition is respected.
    is($long->feature('see'), undef, "scanner stopped before HARNESS-NO-SEE was reached");
};

subtest 'extra_comments: scanner tolerates interleaved comments' => sub {
    my $long = tf_for('extra_comments');
    is($long->check_feature('timeout'),   0, "Timeouts turned off");
    is($long->check_feature('fork'),      1, "Forking allowed");
    is($long->check_feature('preload'),   1, "Preload allowed");
    is($long->check_feature('isolation'), 1, "Isolation on");
    is($long->check_feature('stream'),    1, "Stream default on");

    is($long->check_category, 'isolation', "Category is isolation");
    is($long->check_duration, 'long',      "Duration is long");
    is($long->switches,       [],          "No shebang switches");
};

subtest 'conflicts: parse and dedup across one or more directive lines' => sub {
    is(tf_for('conflicts1')->conflicts,           ['passwd'],          "single tag");
    is([sort @{tf_for('conflicts2')->conflicts}], [qw/daemon passwd/], "two tags on one line");
    is([sort @{tf_for('conflicts3')->conflicts}], [qw/daemon passwd/], "two lines, one with trailing comment");
    is([sort @{tf_for('conflicts4')->conflicts}], [qw/daemon passwd/], "duplicates deduplicated via uniq");
};

subtest 'binary: classified, fork+preload off, no die on non-executable' => sub {
    my $binary = tf_for('binary');

    # Stage C deliberate deviation from legacy: we do NOT die when a
    # binary file is not executable. The runner decides run/exec
    # feasibility, not the parser.
    ok(lives { $binary->scan }, "scan on binary file does not die") or diag $@;

    is($binary->is_binary,                1,  "Binary flag set");
    is($binary->non_perl,                 1,  "non_perl flag set");
    is($binary->check_feature('fork'),    0,  "fork off on binary");
    is($binary->check_feature('preload'), 0,  "preload off on binary");
    is($binary->switches,                 [], "No shebang switches");
};

subtest 'not_perl: bash shebang forces fork/preload off' => sub {
    my $not_perl = tf_for('not_perl');
    is($not_perl->non_perl,                 1, "non_perl flagged");
    is($not_perl->check_feature('fork'),    0, "fork off on bash test");
    is($not_perl->check_feature('preload'), 0, "preload off on bash test");
};

subtest 'not_env_perl: env bash also non_perl' => sub {
    my $env_bash = tf_for('not_env_perl');
    is($env_bash->non_perl,                 1, "env bash non_perl flagged");
    is($env_bash->check_feature('fork'),    0, "fork off on env bash");
    is($env_bash->check_feature('preload'), 0, "preload off on env bash");
};

subtest 'smoke: HARNESS-SMOKE and HARNESS-YES-SMOKE both set features->{smoke}' => sub {
    my $smoke1 = tf_for('smoke1');
    is($smoke1->check_feature('smoke', 0), 1, "HARNESS-SMOKE turns smoke on");

    my $smoke2 = tf_for('smoke2');
    is($smoke2->check_feature('smoke', 0), 1, "HARNESS-YES-SMOKE turns smoke on");
};

subtest 'retry semantics: bare, count, ISO, count+ISO, NO-RETRY' => sub {
    my $retry = tf_for('retry');
    is($retry->retry,          1, "bare HARNESS-RETRY -> retry=1");
    is($retry->retry_isolated, 0, "bare HARNESS-RETRY -> not isolated");

    my $retry5 = tf_for('retry5');
    is($retry5->retry,          5, "HARNESS-RETRY 5 -> retry=5");
    is($retry5->retry_isolated, 0, "count alone is not isolated");

    my $iso = tf_for('retry_iso');
    is($iso->retry,          1, "HARNESS-RETRY-ISO -> retry=1");
    is($iso->retry_isolated, 1, "HARNESS-RETRY-ISO -> isolated");

    my $iso3 = tf_for('retry_iso3');
    is($iso3->retry,          3, "HARNESS-RETRY-ISO 3 -> retry=3");
    is($iso3->retry_isolated, 1, "HARNESS-RETRY-ISO 3 -> isolated");

    my $no = tf_for('no_retry');
    is($no->retry, 0, "HARNESS-NO-RETRY -> retry=0");
};

done_testing;
