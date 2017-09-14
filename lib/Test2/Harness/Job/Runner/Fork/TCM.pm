package Test2::Harness::Job::Runner::Fork::TCM;
use strict;
use warnings;

use parent 'Test2::Harness::Job::Runner::Fork';

sub run {
    my $class = shift;

    my ($pid, $file) = $class->SUPER::run(@_);

    return ($pid, undef) if $pid;

    my $sub = sub {
        $file =~ s{.*lib/}{}g;
        require $file;
        require Test::Class::Moose::Runner;
        Test::Class::Moose::Runner->import();
        Test::Class::Moose::Runner->new->runtests();

        return 0;
    };

    return (undef, $sub);
}

1;
