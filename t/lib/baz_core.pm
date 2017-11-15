package baz_core;
use strict;
use warnings;

BEGIN { CORE::require('foo_core.pm') };
BEGIN { CORE::require('bar_core.pm') };

print "Loaded baz_core\n";

1;
