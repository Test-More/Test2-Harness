use Test2::V0;
use strict;
use warnings;

use Test2::Harness::Util qw/read_file/;
use List::Util qw/first/;

my $dir = first { -d $_ } './lib/App/Yath/Command', '../lib/App/Yath/Command';
opendir(my $DH, $dir) or die "Could not open dir: $!";

for my $file (readdir($DH)) {
    next if $file =~ m/^\./;
    my $path = "$dir/$file";
    next unless -f $path;

    my $load = $path;
    $load =~ s{^.*lib/}{}g;
    require $load;

    my $mod  = "App::Yath::Command::$file";
    $mod =~ s/\.pm$//;

    my $pod = $mod->can('usage_pod') ? $mod->usage_pod : undef;

    unless($pod) {
        note "package $mod does not use generated pod...";
        next;
    }

    my $text = read_file($path);

    ok(index($text, $pod) >= 0, "Generated POD in '$file' is up to date");
}

done_testing;

