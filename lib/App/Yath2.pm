package App::Yath2;
use v5.38;

our $VERSION = '2.000000';

use Object::HashBase qw{
    <script
    <args
    <config
    <user_config
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2 - The yath 2.0 user-interface application.

=head1 DESCRIPTION

C<App::Yath2> owns the user interface: it parses the command line, dispatches to
a command, and lets that command drive L<Test2::Harness2>. This is the
lightweight 2.0 dispatcher; it reads the first argument as a command name and
hands the rest to C<App::Yath2::Command::E<lt>nameE<gt>>.

The harness library (C<Test2::Harness2>) never loads this namespace; the
dependency only runs the other way.

=head1 SYNOPSIS

    my $app = App::Yath2->new(args => ['test', 't/foo.t']);
    exit($app->run);

=head1 ATTRIBUTES

=over 4

=item script

Path to the C<yath> script that launched us (informational).

=item args

Arrayref of command-line arguments: C<[$command, @command_args]>.

=item config, user_config

Paths to the project- and user-level rc files discovered by
L<App::Yath::Script>, or C<undef>.

=back

=cut

# Known commands. A small static table for now; grows as commands are added.
my %COMMANDS = (
    test => 'App::Yath2::Command::test',
);

sub init ($self) {
    $self->{+ARGS} //= [];

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $exit = $app->run

Dispatch to the requested command and return its exit code. With no command, or
C<help> / C<-h> / C<--help>, prints usage. An unknown command prints usage to
STDERR and returns 1.

=back

=cut

sub run ($self) {
    my @args = @{$self->{+ARGS}};
    my $name = shift(@args);

    return $self->_usage(\*STDOUT, 0)
        if !defined($name) || $name eq 'help' || $name eq '-h' || $name eq '--help';

    my $class = $COMMANDS{$name};
    unless ($class) {
        print STDERR "Unknown command: $name\n\n";
        return $self->_usage(\*STDERR, 1);
    }

    my $file = $class =~ s{::}{/}gr . '.pm';
    require $file;

    my $command = $class->new(args => [@args], app => $self);
    return $command->run;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $exit = $self->_usage($fh, $exit)

Print the command list to C<$fh> and return C<$exit>.

=back

=cut

sub _usage ($self, $fh, $exit) {
    print {$fh} "Usage: yath <command> [arguments]\n\nCommands:\n";
    print {$fh} "    $_\n" for sort keys %COMMANDS;
    return $exit;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
