use Test2::V0;
use File::Temp ();

# Run the plugin's BEGIN-time side effects in a child so our own
# $ENV{TMPDIR} / $ENV{TEMPDIR} aren't mutated for the rest of the
# outer test run.

sub run_child {
    my ($setup, $body) = @_;

    my $script = File::Temp->new(SUFFIX => '.pl');
    print $script <<'HEADER';
use strict;
use warnings;
HEADER
    print $script "$setup\n";
    print $script "use Test2::Plugin::IsolateTemp;\n";
    print $script "use Test2::V0;\n";
    print $script "$body\n";
    print $script "done_testing;\n";
    close $script;

    my $out = qx{$^X -I lib $script 2>&1};
    return {out => $out, exit => $?};
}

subtest 'outside of TEST2_HARNESS_ACTIVE, mutates tmp env' => sub {
    my $res = run_child(<<'SETUP', <<'BODY');
BEGIN { delete $ENV{TEST2_HARNESS_ACTIVE} }
SETUP
ok($Test2::Plugin::IsolateTemp::tempdir,
   "plugin allocated a tempdir");
ok(-d $Test2::Plugin::IsolateTemp::tempdir,
   "tempdir exists on disk");

# all four env vars point at the same tempdir
for my $var (qw/TMPDIR TEMPDIR TMP_DIR TEMP_DIR/) {
    is($ENV{$var}, $Test2::Plugin::IsolateTemp::tempdir,
       "\$ENV{$var} points at the tempdir");
}

# sticky-bit set (1777)
my $mode = (stat $Test2::Plugin::IsolateTemp::tempdir)[2];
ok(($mode & 01777) == 01777,
   sprintf("tempdir mode has sticky+777 (got 0%o)", $mode & 07777));
BODY
    is($res->{exit}, 0, 'child exits 0');
    like($res->{out}, qr/ok 1\b/, 'subtest ran the expected assertions');
    unlike($res->{out}, qr/\bnot ok\b/, 'nothing failed in child');
};

subtest 'inside TEST2_HARNESS_ACTIVE, no-op' => sub {
    my $res = run_child(<<'SETUP', <<'BODY');
BEGIN { $ENV{TEST2_HARNESS_ACTIVE} = 1 }
SETUP
is($Test2::Plugin::IsolateTemp::tempdir, undef,
   "no tempdir allocated when running under yath");
BODY
    is($res->{exit}, 0, 'child exits 0');
    unlike($res->{out}, qr/\bnot ok\b/, 'no failures when the plugin no-ops');
};

done_testing;
