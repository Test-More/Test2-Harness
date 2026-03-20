#!/usr/bin/perl
# Helper script for system-child.tx
# Prints @INC entries one per line so the parent can verify
# that include paths are inherited via PERL5LIB.
print "$_\n" for @INC;
