use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();

use Test2::Harness2::DepTracer;
use Test2::Harness2::Reloader;
use Test2::Harness2::Reloader::Exporter;

# Build a throwaway exporter module on disk, import it into a consumer,
# modify the exporter on disk, then call the reload helper. The consumer
# should pick up the new return value without having to re-`use` by hand.

my $dir = tempdir(CLEANUP => 1);
my $exp_dir = File::Spec->catdir($dir, 'ReloadExp');
make_path($exp_dir);

my $exp_file = File::Spec->catfile($exp_dir, 'Mod.pm');

sub write_exporter {
    my ($ret) = @_;
    open my $fh, '>', $exp_file or die $!;
    print $fh <<"EOPM";
package ReloadExp::Mod;
use strict;
use warnings;
use Exporter 'import';
our \@EXPORT_OK = ('give');
sub give { $ret }
1;
EOPM
    close $fh;
}

write_exporter('"ORIG"');

local @INC = ($dir, @INC);

my $dt = Test2::Harness2::DepTracer->new;
$dt->start;

eval q{
    package ReloadExp::Consumer;
    use ReloadExp::Mod 'give';
    sub value { give() }
    1;
} or die $@;

is(ReloadExp::Consumer::value(), 'ORIG', "initial value through imported sub");

# Modify the file to return a new value, then reload via the helper.
write_exporter('"NEW"');

my $info = {
    file      => File::Spec->rel2abs($exp_file),
    module    => 'ReloadExp::Mod',
    inc_entry => 'ReloadExp/Mod.pm',
    perl      => 1,
};

my ($status, %fields) = Test2::Harness2::Reloader::Exporter->reload(
    $info->{file}, $info,
);

ok($status, "exporter reload reports success") or diag($fields{reason});

is(
    ReloadExp::Consumer::value(),
    'NEW',
    "consumer sees updated return value after exporter reload",
);

$dt->stop;

done_testing;
