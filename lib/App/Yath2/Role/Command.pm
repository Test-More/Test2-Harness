package App::Yath2::Role::Command;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'run';

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::Command - Contract for App::Yath2 command classes.

=head1 DESCRIPTION

Role consumed by every C<App::Yath2::Command::*> class. Defines the contract
the dispatcher (L<App::Yath2>) relies on: a C<run> method returning an integer
exit code, plus default class-method getters (C<name>, C<summary>,
C<description>) for help output.

Consuming classes hold their own state (typically via L<Object::HashBase> for
the C<argv> slot the dispatcher passes in) and override C<summary>,
C<description>, and C<run> as needed.

=head1 SYNOPSIS

    package App::Yath2::Command::mycommand;
    use v5.38;

    use Object::HashBase qw{ <argv };
    use Role::Tiny::With;
    with 'App::Yath2::Role::Command';

    sub summary     ($class) { 'One-line summary' }
    sub description ($class) { 'Longer description.' }

    sub run ($self) {
        my @files = @{ $self->argv // [] };
        # ... do work ...
        return 0;
    }

=head1 REQUIRED METHODS

=over 4

=item $exit = $self->run

Execute the command. Must return an integer exit code (0 for success).

=back

=head1 PUBLIC METHODS

=over 4

=item $name = $class->name

Returns the last component of the package name as the command name.
C<App::Yath2::Command::test> returns C<"test">.

=cut

sub name ($class) {
    my $pkg = ref($class) || $class;
    $pkg =~ m/([^:]+)$/;
    return $1;
}

=item $str = $class->summary

One-line summary of the command, shown in help listings. Empty by default;
consumers should override.

=cut

sub summary ($class) { '' }

=item $str = $class->description

Longer description of the command. Empty by default; consumers should override.

=back

=cut

sub description ($class) { '' }

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
