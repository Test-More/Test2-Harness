package Test2::Harness2::Role::Reloader;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Role::Tiny;

# Consumers implement reload_module. Contract is in POD below.
requires 'reload_module';

# Feature gate -- backends that need optional CPAN modules or a
# specific runtime state override to return 0 when they can't run.
sub viable { 1 }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Reloader - Contract for the preload reloader
policies: in-place module reload or kill-and-restart.

=head1 DESCRIPTION

A reloader is consulted once per changed file (after the
L<ChangeWatcher|Test2::Harness2::Role::ChangeWatcher> has reported
a change). It decides whether the change can be absorbed by
re-running the affected module inside the same process (in-place)
or whether the preload stage has to be torn down and re-forked
(kill-and-restart). Per C<IPC_AND_LOGGERS> section 10.5:

=over 4

=item *

L<Test2::Harness2::Reloader::Default> attempts in-place reload
first, with Moose metaclass handling as a special case. Returns
C<not_reloadable> for files it can't handle cleanly (non-trivial
C<import> methods, unknown package associations, etc.).

=item *

L<Test2::Harness2::Reloader::KillRestart> always returns
C<not_reloadable>, forcing the preload resource to fall back to
the branch-pruning path.

=back

The preload resource typically chains multiple reloaders: ask the
Default reloader first, fall back to KillRestart when Default
reports C<not_reloadable>.

=head1 REQUIRED METHOD

=over 4

=item ($status, %fields) = $r->reload_module($module, $file, \%info)

C<$module> is the Perl module name ("Foo::Bar"). C<$file> is the
absolute path of the changed file. C<%info> carries pre-computed
facts about the file:

=over 4

=item file => /abs/path

=item module => "Foo::Bar" (or undef when the file isn't a module)

=item perl => 0/1 (.pm / .pl / .t suffix)

=item has_import => 0/1 (the package defines a non-trivial import())

=item is_moose => 0/1

=item callback => $coderef (a user-supplied watch() callback)

=item churn => [[start_line, code, end_line], ...] from HARNESS-CHURN blocks

=back

Return values:

=over 4

=item (1) -- reload succeeded in place. Stage stays up.

=item (0, reason => $str) -- reload failed. Caller typically
escalates to the next reloader in the chain, or to kill-restart.

=item ('not_reloadable', reason => $str) -- this reloader refuses
to handle the file (policy-level decision, not a runtime failure).

=back

=back

=head1 OPTIONAL METHOD

=over 4

=item $bool = Backend->viable

Feature detection. Default: 1.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
