package App::Yath2;
use v5.38;

our $VERSION = '2.000000';

=pod

=encoding UTF-8

=head1 NAME

App::Yath2 - Command dispatcher for the yath 2.0 command-line tool

=head1 DESCRIPTION

C<App::Yath2> is the top-level dispatcher for C<yath>. It maps a
command name to the corresponding C<App::Yath2::Command::*> class,
instantiates it with the remaining argv, and calls C<run>.

=head1 SYNOPSIS

    # Invoked by the yath script:
    exit App::Yath2->run(@ARGV);

    # Directly:
    exit App::Yath2->run('test', 't/foo.t', 't/bar.t');

=cut

=head1 PUBLIC METHODS

=over 4

=item $exit = $class->run(@argv)

Dispatch C<@argv> to the appropriate command. The first element of C<@argv>
is the command name. Returns an integer exit code. Prints a usage line and
returns 1 when no command is given; prints an error and returns 1 when the
command module cannot be loaded.

=back

=cut

sub run ($class, @argv) {
    my $name = shift @argv;
    unless (defined $name && length $name) {
        print "Usage: yath <command> [args...]\n";
        return 1;
    }

    my $cmd_class = "App::Yath2::Command::$name";
    (my $file = $cmd_class) =~ s{::}{/}g;
    my $ok  = eval { require "$file.pm"; 1 };
    my $err = $@;
    unless ($ok) {
        print "Unknown command '$name'.\n";
        warn $err if $ENV{YATH_DEBUG};
        return 1;
    }

    return $cmd_class->new(argv => \@argv)->run;
}

1;

__END__

=pod

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
