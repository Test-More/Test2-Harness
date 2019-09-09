use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Require::AuthorTesting;

# All these prints intentionally have no newlines
print STDERR "STDERR Before any events";
print STDOUT "STDOUT Before any events";

ok(1, "pass");

print STDERR "STDERR Between events";
print STDOUT "STDOUT Between events";

ok(1, "pass");

print STDERR "STDERR after events";
print STDOUT "STDOUT after events";

done_testing;
