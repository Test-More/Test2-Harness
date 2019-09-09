use Test2::V0;
use File::Spec;
# HARNESS-DURATION-SHORT

my $path = File::Spec->canonpath('t2/relative_paths.t');

skip_all "This test must be run from the project root."
    unless -f $path;

is(__FILE__, $path, "__FILE__ is relative");
is(__FILE__, $0, "\$0 is relative");

sub {
    my ($pkg, $file) = caller(0);
    is($file, $path, "file in caller is relative");
}->();

done_testing;
