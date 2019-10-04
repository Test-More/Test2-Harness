use Test2::V0;
# HARNESS-NO-PRELOAD

use File::Find;
use Test2::Harness;
use Test2::Harness::Util qw/file2mod/;

find(\&wanted, 'lib/');

sub wanted {
    my $file = $File::Find::name;
    return unless $file =~ m/\.pm$/;

    $file =~ s{^.*lib/}{}g;
    my $ok = eval { require($file); 1 };
    my $err = $@;
    ok($ok, "require $file", $ok ? () : $err);

    my $mod = file2mod($file);
    my $sym = "$mod\::VERSION";
    no strict 'refs';
    is($$sym, $Test2::Harness::VERSION, "Package $mod has the version number");
};

done_testing;
