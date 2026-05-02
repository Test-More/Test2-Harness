use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::TestFile;

my $tdir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    binmode($fh);
    print {$fh} $content;
    close($fh);
    return $path;
}

sub tf_for {
    my ($name, @lines) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    my $body = join("\n", @lines) . "\nuse strict;\n";
    write_file($path, $body);
    return App::Yath2::TestFile->new(file => $path);
}

sub tf_bytes {
    my ($name, $bytes) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    write_file($path, $bytes);
    return App::Yath2::TestFile->new(file => $path);
}

# ---- check_feature: defaults table ----

subtest 'check_feature returns per-feature defaults for untouched features' => sub {
    my $tf = tf_for('plain.t', '#!/usr/bin/perl');
    is($tf->check_feature('timeout'),   1, 'timeout default 1');
    is($tf->check_feature('fork'),      1, 'fork default 1 on plain perl test');
    is($tf->check_feature('preload'),   1, 'preload default 1 on plain perl test');
    is($tf->check_feature('stream'),    1, 'stream default 1');
    is($tf->check_feature('run'),       1, 'run default 1');
    is($tf->check_feature('io_events'), 1, 'io_events default 1');
    is($tf->check_feature('isolation'), 0, 'isolation default 0');
    is($tf->check_feature('smoke'),     0, 'smoke default 0');
};

subtest 'Explicit default argument overrides the feature table' => sub {
    my $tf = tf_for('plain.t', '#!/usr/bin/perl');
    is($tf->check_feature('made_up',   1), 1, 'caller default 1 wins for unknown feature');
    is($tf->check_feature('made_up',   0), 0, 'caller default 0 wins for unknown feature');
    is($tf->check_feature('isolation', 1), 1, 'caller default overrides the table default');
};

subtest 'Directive-set features beat the defaults table' => sub {
    my $notimeout = tf_for('no_timeout.t', '#!/usr/bin/perl', '# HARNESS-NO-TIMEOUT');
    is($notimeout->check_feature('timeout'), 0, 'NO-TIMEOUT wins over default 1');

    my $useiso = tf_for('use_iso.t', '#!/usr/bin/perl', '# HARNESS-USE-ISOLATION');
    is($useiso->check_feature('isolation'), 1, 'USE-ISOLATION wins over default 0');
};

# ---- check_duration ----

subtest 'check_duration fallback chain' => sub {
    my $plain = tf_for('plain_d.t', '#!/usr/bin/perl');
    is($plain->check_duration, 'medium', 'no directive, timeout on -> medium');

    my $no_to = tf_for('no_to_d.t', '#!/usr/bin/perl', '# HARNESS-NO-TIMEOUT');
    is($no_to->check_duration, 'long', 'NO-TIMEOUT lifts duration to long');

    my $short = tf_for('dur_short.t', '#!/usr/bin/perl', '# HARNESS-DURATION-SHORT');
    is($short->check_duration, 'short', 'explicit DURATION-SHORT wins');

    my $short_notimeout = tf_for(
        'short_notimeout.t',        '#!/usr/bin/perl',
        '# HARNESS-DURATION-SHORT', '# HARNESS-NO-TIMEOUT',
    );
    is(
        $short_notimeout->check_duration,
        'short',
        'explicit DURATION still wins when NO-TIMEOUT is also set',
    );
};

# ---- check_category ----

subtest 'check_category fallback chain' => sub {
    my $plain = tf_for('plain_c.t', '#!/usr/bin/perl');
    is($plain->check_category, 'general', 'no directive -> general');

    my $iso = tf_for('iso_c.t', '#!/usr/bin/perl', '# HARNESS-USE-ISOLATION');
    is($iso->check_category, 'isolation', 'USE-ISOLATION lifts category to isolation');

    my $cat = tf_for('cat_io.t', '#!/usr/bin/perl', '# HARNESS-CATEGORY-IO');
    is($cat->check_category, 'io', 'explicit CATEGORY-IO wins');

    my $cat_iso = tf_for(
        'cat_iso.t',             '#!/usr/bin/perl',
        '# HARNESS-CATEGORY-IO', '# HARNESS-USE-ISOLATION',
    );
    is(
        $cat_iso->check_category,
        'io',
        'explicit CATEGORY still wins when USE-ISOLATION is also set',
    );
};

# ---- check_stage / check_min_slots / check_max_slots ----

subtest 'check_stage / check_min_slots / check_max_slots pass-through' => sub {
    my $plain = tf_for('plain_s.t', '#!/usr/bin/perl');
    is($plain->check_stage,     undef, 'stage undef without directive');
    is($plain->check_min_slots, 1,     'min_slots init default is 1');
    is($plain->check_max_slots, undef, 'max_slots init default is undef');

    my $set = tf_for(
        'set_s.t',                 '#!/usr/bin/perl',
        '# HARNESS-STAGE-DBStage', '# HARNESS-JOB-SLOTS 2 4',
    );
    is($set->check_stage,     'DBStage', 'stage returned case-preserved');
    is($set->check_min_slots, 2,         'min_slots returned as stored');
    is($set->check_max_slots, 4,         'max_slots returned as stored');
};

# ---- fork / preload safety override ----

subtest 'perl -w only: fork and preload stay enabled' => sub {
    my $tf = tf_for('dashw.t', '#!/usr/bin/perl -w');
    is($tf->check_feature('fork'),    1, 'fork still 1 with -w only');
    is($tf->check_feature('preload'), 1, 'preload still 1 with -w only');
};

subtest 'perl -T: fork and preload auto-disabled' => sub {
    my $tf = tf_for('taint.t', '#!/usr/bin/perl -T');
    is($tf->check_feature('fork'),    0, '-T forces fork off');
    is($tf->check_feature('preload'), 0, '-T forces preload off');
};

subtest 'perl -w -Mblib: -Mblib forces fork off even with -w present' => sub {
    my $tf = tf_for('blib.t', '#!/usr/bin/perl -w -Mblib');
    is($tf->check_feature('fork'),    0, 'any non-w switch disables fork');
    is($tf->check_feature('preload'), 0, 'any non-w switch disables preload');
};

subtest 'bash shebang: fork and preload disabled (non-perl)' => sub {
    my $tf = tf_for('bash.t', '#!/usr/bin/bash');
    is($tf->check_feature('fork'),    0, 'non_perl forces fork off');
    is($tf->check_feature('preload'), 0, 'non_perl forces preload off');
};

subtest 'binary fixture: fork and preload disabled' => sub {
    my $bytes = pack 'C*', map { int rand 256 } 1 .. 512;
    my $name  = 'bin.t';
    my $path  = File::Spec->catfile($tdir, $name);
    write_file($path, $bytes);
    # App::Yath2::TestFile refuses non-executable binaries (legacy
    # idiom); flip the bit before construction.
    chmod 0755, $path or die "chmod $path: $!";
    my $tf = App::Yath2::TestFile->new(file => $path);
    is($tf->check_feature('fork'),    0, 'is_binary forces fork off');
    is($tf->check_feature('preload'), 0, 'is_binary forces preload off');
};

subtest 'safety override beats explicit HARNESS-USE-FORK' => sub {
    my $tf = tf_for('bash_usefork.t', '#!/usr/bin/bash', '# HARNESS-USE-FORK');
    is($tf->check_feature('fork'), 0, 'USE-FORK on non-perl test still returns 0');
};

# ---- scan is invoked lazily by each check_* ----

subtest 'check_feature triggers scan on first call' => sub {
    my $tf = tf_for('lazy.t', '#!/usr/bin/perl', '# HARNESS-NO-STREAM');

    # Construct a TestFile but do NOT call scan directly. _scanned is
    # an internal HashBase slot (no public reader); poke the slot
    # constant directly.
    ok(!$tf->{+App::Yath2::TestFile::_SCANNED}, '_scanned starts false');

    is($tf->check_feature('stream'), 0, 'check_feature sees directive value');
    ok($tf->{+App::Yath2::TestFile::_SCANNED}, '_scanned latched by check_feature');
};

done_testing;
