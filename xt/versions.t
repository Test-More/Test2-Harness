use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Find qw/find/;

require Test2::Harness;
my $version = Test2::Harness->VERSION;

my @to_load;

find(
    sub {
        return unless m/\.pm/;
        return if m/HashBase\.pm$/;
        push @to_load => $File::Find::name;
    },
    'lib',
);

for my $file (@to_load) {
    $file =~ s{^.*lib/}{}g;
    require $file;

    my $pkg = $file;
    $pkg =~ s/\.pm$//g;
    $pkg =~ s{/}{::}g;

    is($pkg->VERSION, $version, "Got version for $pkg, and it matches the expected version");
}

done_testing;
