package SmokePlugin;
use strict;
use warnings;

use parent 'App::Yath2::Plugin';

sub munge_files {
    my $self = shift;
    my ($tests, $settings) = @_;

    for my $test (@$tests) {
        next unless $test->relative =~ m/[aceg]\.tx$/;
        $test->set_smoke;
    }
}

1;
