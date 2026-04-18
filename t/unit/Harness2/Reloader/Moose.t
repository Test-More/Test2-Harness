use Test2::V0;
use strict;
use warnings;

BEGIN {
    plan skip_all => "Moose not installed"
        unless eval { require Moose; 1 };
}

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();

use Test2::Harness2::Reloader::Moose;

ok(Test2::Harness2::Reloader::Moose->viable, "viable when Moose is present");

my $dir = tempdir(CLEANUP => 1);
my $mod_dir = File::Spec->catdir($dir, 'MooseReload');
make_path($mod_dir);

my $mod_file = File::Spec->catfile($mod_dir, 'Foo.pm');

sub write_class {
    my ($ret) = @_;
    open my $fh, '>', $mod_file or die $!;
    print $fh <<"EOPM";
package MooseReload::Foo;
use Moose;
sub greet { '$ret' }
no Moose;
__PACKAGE__->meta->make_immutable;
1;
EOPM
    close $fh;
}

write_class('hello');

local @INC = ($dir, @INC);
require MooseReload::Foo;

is(MooseReload::Foo->new->greet, 'hello', "initial greet");

# Modify on disk and reload.
write_class('goodbye');

my $info = {
    file      => File::Spec->rel2abs($mod_file),
    module    => 'MooseReload::Foo',
    inc_entry => 'MooseReload/Foo.pm',
    perl      => 1,
};

my ($status, %fields) = Test2::Harness2::Reloader::Moose->reload(
    $info->{file}, $info,
);
ok($status, "Moose reload reports success") or diag($fields{reason});

is(
    MooseReload::Foo->new->greet,
    'goodbye',
    "new instance sees updated method body",
);

done_testing;
