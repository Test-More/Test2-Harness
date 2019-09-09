use strict;
use warnings;
use Test2::Tools::Tiny;
use File::Spec;
# HARNESS-DURATION-SHORT

my $file = __FILE__;
$file =~ s/\.t$/.pm/;
$file = File::Spec->rel2abs($file);

require $file;

ok(file_loaded(), "file loaded, proper namespace, etc");

done_testing;
