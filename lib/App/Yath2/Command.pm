package App::Yath2::Command;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Object::HashBase qw{ <argv };

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command - Base class for App::Yath2 command objects

=head1 DESCRIPTION

Base class for all C<App::Yath2> commands. Provides the common interface:
C<name>, C<summary>, C<description>, and C<run>. Subclasses override
C<summary>, C<description>, and C<run>.

=head1 SYNOPSIS

    package App::Yath2::Command::mycommand;
    use parent 'App::Yath2::Command';

    sub summary     ($class) { 'One-line summary' }
    sub description ($class) { 'Longer description.' }

    sub run ($self) {
        my @files = @{$self->argv // []};
        # ... do work ...
        return 0;
    }

=head1 ATTRIBUTES

=over 4

=item argv

Arrayref of command-line arguments that follow the command name.

=back

=cut

=head1 PUBLIC METHODS

=over 4

=item $name = $class->name

Returns the last component of the package name, lower-cased as the
command name. For example, C<App::Yath2::Command::test> returns C<test>.

=cut

sub name ($class) {
    my $pkg = ref($class) || $class;
    $pkg =~ m/([^:]+)$/;
    return $1;
}

=item $str = $class->summary

One-line summary of the command, shown in help listings. Returns an empty
string in the base class; subclasses should override.

=cut

sub summary ($class) { '' }

=item $str = $class->description

Longer description of the command. Returns an empty string in the base
class; subclasses should override.

=cut

sub description ($class) { '' }

=item $exit = $self->run

Execute the command. Returns an integer exit code (0 for success). The
base class croaks; subclasses must override.

=back

=cut

sub run ($self) { croak ref($self) . " must implement run()" }

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
