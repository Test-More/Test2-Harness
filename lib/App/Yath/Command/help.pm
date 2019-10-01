package App::Yath::Command::help;
use strict;
use warnings;

use Test2::Util qw/pkg_to_file/;

our $VERSION = '0.001100';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/<_command_info_hash/;

use Test2::Harness::Util qw/open_file find_libraries/;
use List::Util ();

sub options {};
sub group { '' }
sub summary { 'Show the list of commands' }

sub description {
    return <<"    EOT"
This command provides a list of commands when called with no arguments.
When given a command name as an argument it will print the help for that
command.
    EOT
}

sub command_info_hash {
    my $self = shift;

    return $self->{+_COMMAND_INFO_HASH} if $self->{+_COMMAND_INFO_HASH};

    my %commands;
    my $command_libs = find_libraries('App::Yath::Command::*');
    for my $lib (sort keys %$command_libs) {
        my $ok = eval { require $command_libs->{$lib}; 1 };
        unless ($ok) {
            warn "Failed to load command '$command_libs->{$lib}': $@";
            next;
        }

        next if $lib->internal_only;
        my $name = $lib->name;
        my $group = $lib->group;
        $commands{$group}->{$name} = $lib->summary;
    }

    return $self->{+_COMMAND_INFO_HASH} = \%commands;
}

sub command_list {
    my $self = shift;

    my $command_hash = $self->command_info_hash();
    my @commands = map keys %$_, values %$command_hash;
    return @commands;
}

sub run {
    my $self = shift;
    my $args = $self->{+ARGS};

    return $self->command_help($args->[0]) if @$args;

    my $script = $self->settings->yath->script // $0;
    my $maxlen = List::Util::max(map length, $self->command_list);

    print "\nUsage: $script COMMAND [options]\n\nAvailable Commands:\n";

    my $command_info_hash = $self->command_info_hash;
    for my $group (sort keys %$command_info_hash) {
        my $set = $command_info_hash->{$group};

        printf("    %${maxlen}s:  %s\n", $_, $set->{$_}) for sort keys %$set;
        print "\n";
    }

    return 0;
}

sub command_help {
    my $self = shift;
    my ($command) = @_;

    require App::Yath;
    my $cmd_class = App::Yath->load_command($command);
    print $cmd_class->cli_help(settings => $self->{+SETTINGS});

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

