use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::TestFile;

my $tdir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} $content;
    close($fh);
    return $path;
}

sub tf_for {
    my ($name, @directives) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    my $body = "#!/usr/bin/perl\n" . join("\n", @directives) . "\nuse strict;\n";
    write_file($path, $body);
    return App::Yath2::TestFile->new(file => $path);
}

# ---- TIMEOUT ----

subtest 'HARNESS-TIMEOUT EVENT 90 sets event_timeout' => sub {
    my $tf = tf_for('to_event.t', '# HARNESS-TIMEOUT EVENT 90');
    $tf->scan;
    is($tf->event_timeout,     90,    'event_timeout set');
    is($tf->post_exit_timeout, undef, 'post_exit_timeout untouched');
};

subtest 'HARNESS-TIMEOUT POSTEXIT 30 sets post_exit_timeout' => sub {
    my $tf = tf_for('to_postexit.t', '# HARNESS-TIMEOUT POSTEXIT 30');
    $tf->scan;
    is($tf->post_exit_timeout, 30,    'post_exit_timeout set');
    is($tf->event_timeout,     undef, 'event_timeout untouched');
};

subtest 'HARNESS-TIMEOUT-EVENT-15 (dash form) sets event_timeout' => sub {
    my $tf = tf_for('to_dash.t', '# HARNESS-TIMEOUT-EVENT-15');
    $tf->scan;
    is($tf->event_timeout, 15, 'dash-delimited form parses');
};

subtest 'HARNESS-TIMEOUT POST EXIT 60 collapses to postexit' => sub {
    my $tf = tf_for('to_postexit_spaced.t', '# HARNESS-TIMEOUT POST EXIT 60');
    $tf->scan;
    is($tf->post_exit_timeout, 60, 'POST + EXIT collapsed to postexit');
};

subtest 'HARNESS-TIMEOUT WAT 30 warns and does not set a timeout' => sub {
    my $tf       = tf_for('to_invalid.t', '# HARNESS-TIMEOUT WAT 30');
    my $warnings = warnings { $tf->scan };
    is(scalar @$warnings, 1, 'one warning');
    like(
        $warnings->[0],
        qr/'WAT' is not a valid timeout type, use 'EVENT' or 'POSTEXIT'/,
        'warning text names the bad token',
    );
    is($tf->event_timeout,     undef, 'event_timeout stays undef');
    is($tf->post_exit_timeout, undef, 'post_exit_timeout stays undef');
};

# ---- JOB SLOTS ----

subtest 'HARNESS-JOB-SLOTS 2 sets min and max to 2' => sub {
    my $tf = tf_for('slots_1.t', '# HARNESS-JOB-SLOTS 2');
    $tf->scan;
    is($tf->min_slots, 2, 'min_slots == 2');
    is($tf->max_slots, 2, 'max_slots defaults to min when no second arg');
};

subtest 'HARNESS-JOB-SLOTS 2 4 sets min=2, max=4' => sub {
    my $tf = tf_for('slots_2.t', '# HARNESS-JOB-SLOTS 2 4');
    $tf->scan;
    is($tf->min_slots, 2, 'min_slots == 2');
    is($tf->max_slots, 4, 'max_slots == 4');
};

subtest 'HARNESS-JOB SLOTS 1 8 (space form) sets min=1, max=8' => sub {
    my $tf = tf_for('slots_3.t', '# HARNESS-JOB SLOTS 1 8');
    $tf->scan;
    is($tf->min_slots, 1, 'space-separated JOB SLOTS parses');
    is($tf->max_slots, 8, 'max_slots == 8');
};

# ---- CONFLICTS ----

subtest 'HARNESS-CONFLICTS PASSWD sets a single conflict' => sub {
    my $tf = tf_for('c_1.t', '# HARNESS-CONFLICTS PASSWD');
    $tf->scan;
    is($tf->conflicts, ['passwd'], 'conflict lowercased');
};

subtest 'HARNESS-CONFLICTS PASSWD NETWORK (single line, multiple args)' => sub {
    my $tf = tf_for('c_2.t', '# HARNESS-CONFLICTS PASSWD NETWORK');
    $tf->scan;
    is($tf->conflicts, ['passwd', 'network'], 'multi-arg single line');
};

subtest 'Multiple HARNESS-CONFLICTS lines accumulate' => sub {
    my $tf = tf_for('c_3.t', '# HARNESS-CONFLICTS PASSWD', '# HARNESS-CONFLICTS NETWORK');
    $tf->scan;
    is($tf->conflicts, ['passwd', 'network'], 'two lines accumulate');
};

subtest 'Duplicate conflicts are deduped' => sub {
    my $tf = tf_for(
        'c_dup.t', '# HARNESS-CONFLICTS PASSWD NETWORK',
        '# HARNESS-CONFLICTS PASSWD',
    );
    $tf->scan;
    is($tf->conflicts, ['passwd', 'network'], 'uniq across lines');
};

# ---- META ----

subtest 'HARNESS-META author exodist (space form)' => sub {
    my $tf = tf_for('m_space.t', '# HARNESS-META author exodist');
    $tf->scan;
    is($tf->meta->{author}, ['exodist'], 'author => [exodist]');
};

subtest 'HARNESS-META-build-debug (dash form)' => sub {
    my $tf = tf_for('m_dash.t', '# HARNESS-META-build-debug');
    $tf->scan;
    is($tf->meta->{build}, ['debug'], 'build => [debug]');
};

subtest 'Repeated HARNESS-META keys accumulate values in order' => sub {
    my $tf = tf_for('m_repeat.t', '# HARNESS-META author X', '# HARNESS-META author Y');
    $tf->scan;
    is($tf->meta->{author}, ['X', 'Y'], 'two values in insertion order');
};

subtest 'HARNESS-META AUTHOR exodist  # trailing comment' => sub {
    my $tf = tf_for('m_comment.t', '# HARNESS-META AUTHOR exodist  # trailing');
    $tf->scan;
    is($tf->meta->{author}, ['exodist'], 'key lowercased, trailing comment stripped');
};

done_testing;
