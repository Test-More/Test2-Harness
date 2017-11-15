package bar_core;
use strict;
use warnings;

BEGIN { CORE::require('foo_core.pm') };

print "Loaded bar_core\n";

1;
