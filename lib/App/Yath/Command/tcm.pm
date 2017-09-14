package App::Yath::Command::tcm;
use strict;
use warnings;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub internal_only { 1 }
sub show_bench { 0 }

sub run {
    my $self = shift;

    my $args = $self->{+ARGS};
    my $file = shift @$args;

    $file =~ s{.*lib/}{}g;
    require $file;

    require Test::Class::Moose::Runner;
    Test::Class::Moose::Runner->import;

    Test::Class::Moose::Runner->new->runtests;

    return 0;
}

1;
