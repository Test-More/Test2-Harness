use Test2::Tools::Basic;
use Test2::Tools::Subtest qw/subtest_buffered subtest_streamed/;
BEGIN {
    require Test::More;
    *subtest_legacy = \&Test::More::subtest;
}

subtest_buffered subtest_buffered => sub {
    ok(1, "buffered shallow A");
    subtest_buffered "buffered inner" => sub {
        ok(1, "buffered deep");
        note "Nested Note";
        print STDOUT "Nested STDOUT print\n";
        diag "Nested Diag";
        print STDERR "Nested STDERR print\n";
        warn "Nested warning\n";
    };
    ok(1, "buffered shallow B");
};

subtest_streamed subtest_streamed => sub {
    ok(1, "streamed shallow A");
    subtest_streamed "streamed inner" => sub {
        ok(1, "streamed deep");
        note "Nested Note";
        print STDOUT "Nested STDOUT print\n";
        diag "Nested Diag";
        print STDERR "Nested STDERR print\n";
        warn "Nested warning\n";
    };
    ok(1, "streamed shallow B");
};

subtest_legacy legacy_subtest => sub {
    ok(1, "legacy shallow A");
    subtest_legacy "legacy inner" => sub {
        ok(1, "legacy deep");
        note "Nested Note";
        print STDOUT "Nested STDOUT print\n";
        diag "Nested Diag";
        print STDERR "Nested STDERR print\n";
    };
    ok(1, "legacy shallow B");
};

print <<EOT;
# Subtest: tap_subtest
    ok - tap shallow A
    # Subtest: tap inner
        ok - tap deep
        # Nested Note
Nested STDOUT print
EOT
print STDERR <<EOT;
        # Nested Diag
Nested STDERR print
EOT
warn "Nested warning\n";
print <<EOT;
        1..1
    ok - tap inner
    ok - tap shallow B
    1..3
ok - tap_subtest
EOT

print "1..4\n";
use POSIX;
POSIX::_exit(0);

