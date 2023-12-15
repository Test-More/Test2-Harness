package App::Yath::Command::help;
use strict;
use warnings;

use Term::Table();

our $VERSION = '2.000000';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/<_command_info_hash/;

use Test2::Harness::Util qw/find_libraries mod2file/;
use List::Util ();

sub group { ' main' }
sub summary { 'Show the list of commands' }

sub description {
    return <<"    EOT"
This command provides a list of commands when called with no arguments.
When given a command name as an argument it will print the help for that
command.
    EOT
}

use Getopt::Yath;
option_group {group => 'help', category => "Help Options"} => sub {
    option verbose => (
        type => 'Count',
        short => 'v',
        description => "Show commands that would normally be omitted such as internal and deprecated",
    );
};

sub command_info_hash {
    my $self = shift;

    return $self->{+_COMMAND_INFO_HASH} if $self->{+_COMMAND_INFO_HASH};

    my $settings = $self->{+SETTINGS};
    my $hs = $settings->help;

    my %commands;
    my $command_libs = find_libraries('App::Yath::Command::*');
    for my $lib (sort keys %$command_libs) {
        my $ok = eval {
            local $SIG{__WARN__} = sub { 1 };
            require $command_libs->{$lib};
            1
        };
        unless ($ok) {
            my ($err) = split /\n/, $@;
            my $short = $lib;
            $short =~ s/^App::Yath::Command:://;

            if ($err =~ m/Module '\Q$lib\E' has been deprecated/) {
                push @{$commands{'z  deprecated'}} => [$short, "This command is deprecated"] if $hs->verbose;
                next;
            }

            push @{$commands{'z  failed to load'}} => [$short, $err];
            next;
        }

        next unless $lib->isa('App::Yath::Command');
        my $internal = $lib->internal_only;
        next if $internal && !$hs->verbose;
        my $name = $lib->name;
        my $group = $internal ? 'z  internal only' : $lib->group;
        push @{$commands{$group}} => [$name, $lib->summary];
    }

    return $self->{+_COMMAND_INFO_HASH} = \%commands;
}

sub run {
    my $self = shift;
    my $args = $self->{+ARGS};

    return $self->command_help($args->[0]) if @$args;

    my $script = $self->settings->yath->script // $0;

    print "\nUsage: $script help [-v] [COMMAND]\n";

    my $command_info_hash = $self->command_info_hash;
    for my $group (sort keys %$command_info_hash) {
        my $set = $command_info_hash->{$group};

        my $printable = $group;
        $printable =~ s/^\s+//g;
        $printable =~ s/\s+$//g;
        $printable =~ s/^z\s+//g;
        print "\n\n" . ucfirst($printable) . " commands:\n";

        my $table = Term::Table->new(
            rows   => [ sort { $a->[0] cmp $b->[0] } @$set ],
        );
        print map { "$_\n" } $table->render;
    }

    return 0;
}

sub command_help {
    my $self = shift;
    my ($command) = @_;

    require App::Yath;
    my $cmd_class = "App::Yath::Command::$command";
    require(mod2file($cmd_class));

    my $app = App::Yath->new(command => $cmd_class, settings => $self->settings);
    $app->options->include($cmd_class->options);
    print $app->cli_help();

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

