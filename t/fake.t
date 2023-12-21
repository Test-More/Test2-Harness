#!/usr/bin/perl
use Test2::V0;
# HARNESS-SMOKE
# HARNESS-STAGE-theone

STDOUT->autoflush(1);

use Carp qw/longmess/;

use Data::Dumper;
print STDERR "WARN: " . ($^W || 0) . "\n";
print STDERR "ARGS " . Dumper(\@ARGV);

ok(1, "An assertion");

print "Hi!\n";
print STDERR "Hi!\n";

note "A Note!";
diag "A Diag!";

print "Trace: " . longmess();

print "STAGE: $ENV{T2_HARNESS_STAGE}\n";

warn "This is a warning";

print "AAA\n";
#bail_out "foo";
print "AAB\n";

for (1 .. 100) {
for (1 .. 5) {
    sleep 1;
    print STDOUT " $_";
    STDOUT->flush();
}
print "\n";
}

print STDOUT "Enter Text: ";
STDOUT->flush();
my $got = <STDIN> // '<UNDEF>';
chomp($got);
print "Got: $got\n";

print STDOUT "Enter a key: ";
#require Term::ReadKey;
#Term::ReadKey::ReadMode(3);
#`stty echo`;
my $x = getc(STDIN);
print "\nGot Key: |$x|\n";

subtest subtest_a => sub {
    print "***** " . Test2::API::test2_trace_stamps_enabled . " | $ENV{T2_TRACE_STAMPS} *****\n";
    ok(1);
};

subtest subtest_b => sub {
    subtest subtest_ba => sub {
        subtest subtest_bb => sub {
            ok(0);
        };
    };
};

subtest subtest_c => sub {
    ok(0);
};

subtest undef, sub {
    ok(0);
};

diag "TMPDIR: $ENV{TMPDIR}\n";

done_testing;
