package tpree;
use strict;
use warnings;

use parent 'Test2::Harness::Preload';

use Test2::Util qw/pkg_to_file/;

sub preload {
    my $class = shift;
    my %params = @_;

    my $block = $params{block} || {};

    use Data::Dumper;
    print Dumper(\%params);

    for my $mod ('foo', 'bar', 'baz') {
        next if $block->{$mod};
        my $file = pkg_to_file($mod);
        require $file;
    }
}

print "Loaded tpree\n";

1;
