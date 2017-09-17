use Test2::V0;
use strict;
use warnings;

use Test2::Util qw/pkg_to_file/;
use Module::Pluggable search_path => ['App::Yath::Command'];

use Test2::Harness::Util qw/read_file/;

for my $pkg (__PACKAGE__->plugins) {
    my $file = pkg_to_file($pkg);
    require $file;

    my $pod = $pkg->can('generate_pod') ? $pkg->generate_pod : undef;

    unless($pod) {
        note "package $pkg does not use generated pod...";
        next;
    }

    my $text = read_file($INC{$file});

    ok(index($text, $pod) >= 0, "Generated POD in '$file' is up to date");
}

done_testing;

