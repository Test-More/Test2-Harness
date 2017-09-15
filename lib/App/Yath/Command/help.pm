package App::Yath::Command::help;
use strict;
use warnings;

use Test2::Util qw/pkg_to_file/;

our $VERSION = '0.001014';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Test2::Harness::Util qw/open_file/;

sub show_bench { 0 }

sub summary { 'Show a this list of commands' }

sub group { '' }

sub run {
    my $self = shift;

    my $args = $self->{+ARGS};

    return $self->command_help(shift @$args) if @$args;

    require Module::Pluggable;
    Module::Pluggable->import(search_path => ['App::Yath::Command']);

    my $len = 0;
    my %commands;
    for my $pkg ($self->plugins) {
        my $file = pkg_to_file($pkg);
        eval {
            require $file;

            unless($pkg->internal_only) {
                my $group = $pkg->group;
                my $name = $pkg->name;

                $commands{$group}->{$name} = $pkg->summary;
                my $l = length($name);
                $len = $l if $l > $len;
            }
            1;
        };
    }

    print "\nUsage: $0 COMMAND [options]\n\nAvailable Commands:\n";

    for my $group (sort keys %commands) {
        my $set = $commands{$group};

        printf("    %${len}s:  %s\n", $_, $set->{$_}) for sort keys %$set;
        print "\n";
    }

    return 0;
}

sub command_help {
    my $self = shift;
    my ($command) = @_;

    require App::Yath;
    my $cmd_class = App::Yath->load_command($command);
    print $cmd_class->new->usage;

    return 0;
}

1;
