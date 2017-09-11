package Test2::Harness::Job::Runner::Fork::TCM;
use strict;
use warnings;

use parent 'Test2::Harness::Job::Runner::Fork';

sub run {
    my $class = shift;

    my ($pid, $file) = $class->SUPER::run(@_);

    return ($pid, $file) if $pid;

    my $sub = sub {
        require Test2::Require::Module;
        Test2::Require::Module->import('Test::Class::Moose::Runner');
        require $file;
        require Test::Class::Moose::Runner;
        Test::Class::Moose::Runner->import();
        Test::Class::Moose::Runner->new->runtests();
    };

    return (undef, $sub);
}

1;
