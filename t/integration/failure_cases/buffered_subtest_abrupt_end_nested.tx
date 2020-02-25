use strict;
use warnings;

my $end = $ENV{FAILURE_DO_PASS} ? "}\n    " : "";

print <<EOT;
ok - outer {
    ok - foo {
        ok - pass
        1..1
    ${end}ok - bar
    1..2
}
1..1
EOT

exit 0;
