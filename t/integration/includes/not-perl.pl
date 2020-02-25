use Test2::V0;
use File::Spec;
use Config qw/%Config/;

my @parts = File::Spec->splitpath(File::Spec->rel2abs(__FILE__));
pop @parts;
my $path = File::Spec->catpath(@parts);

use App::Yath;

like(
    \@INC,
    [
        App::Yath->app_path,
        File::Spec->catdir($path, 'xyz'),
        File::Spec->catdir($path, 'lib'),
        File::Spec->catdir($path, 'blib', 'lib'),
        File::Spec->catdir($path, 'blib', 'arch'),
    ],
    "Added all the expected paths in order"
);

like(
    [split $Config{path_sep}, $ENV{PERL5LIB}],
    [
        App::Yath->app_path,
        File::Spec->catdir($path, 'xyz'),
        File::Spec->catdir($path, 'lib'),
        File::Spec->catdir($path, 'blib', 'lib'),
        File::Spec->catdir($path, 'blib', 'arch'),
    ],
    "When running non-perl the libs were added via PERL5LIB"
);

done_testing;
