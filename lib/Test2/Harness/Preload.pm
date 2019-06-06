package Test2::Harness::Preload;
use strict;
use warnings;

our $VERSION = '0.001078';

sub stages { () }
sub fork_stages { () }

sub preload {
    my $class = shift;
    my ($do_not_load, $job_count) = @_;
    die "$class does not override preload()";
}

sub pre_fork {
    my $class = shift;
    my ($job) = @_;
}

sub post_fork {
    my $class = shift;
    my ($job) = @_;
}

sub pre_launch {
    my $class = shift;
    my ($job) = @_;
}


1;
