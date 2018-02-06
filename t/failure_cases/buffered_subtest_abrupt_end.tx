use strict;
use warnings;

my $end = $ENV{FAILURE_DO_PASS} ? "}\n" : "";

print <<EOT;
ok - foo {
    ok - pass
    1..1
${end}ok - bar
1..2
EOT

exit 0;
