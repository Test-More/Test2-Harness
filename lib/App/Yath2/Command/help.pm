package App::Yath2::Command::help;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

# `yath help [COMMAND]` -- currently a minimal dispatcher on top of
# App::Yath2's own usage banner. When given a command name, prints
# the command-specific help if the command's module exposes one;
# otherwise falls back to "not-yet-implemented". The full
# Getopt::Yath-driven per-command help arrives as each command grows
# its own doc stanza.
sub run {
    my $self = shift;

    my $target = (defined $self->argv->[0] && $self->argv->[0] !~ /^-/) ? $self->argv->[0] : undef;

    unless (defined $target) {
        require App::Yath2;
        my $app = App::Yath2->new(
            script => $self->{+SCRIPT},
            argv   => ['--help'],
            config => $self->{+CONFIG},
        );
        return $app->run;
    }

    my $class = "App::Yath2::Command::$target";
    (my $file = $class) =~ s{::}{/}g;
    $file .= '.pm';

    my $loaded = eval { require $file; 1 };
    unless ($loaded) {
        print STDERR "yath help: no command named '$target'.\n";
        return 2;
    }

    if ($class->can('help')) {
        print $class->help;
        return 0;
    }

    # No per-command help yet. Print a minimum acknowledgement.
    print "No detailed help available for '$target' yet. See PLAN for status.\n";
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::help - Print top-level or per-command help.

=head1 DESCRIPTION

With no args, prints the same usage banner C<yath --help> produces.
With a command name, loads that command's module and prints its
C<help> method's return value if the module defines one. When the
module has no C<help> method, a short "no detailed help yet"
message is printed so users at least know the command exists.

=head1 STATUS

Stage 13: the minimum viable help dispatcher. Per-command help
arrives incrementally as commands grow their Getopt::Yath-driven
doc stanzas.

=cut
