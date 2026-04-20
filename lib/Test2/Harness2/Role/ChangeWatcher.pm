package Test2::Harness2::Role::ChangeWatcher;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Role::Tiny;

# Consumers implement these. Signatures in POD below.
requires 'watch';
requires 'changed_files';

# Feature-detection hook so the preload resource can pick a working
# watcher implementation at runtime. Default is "this backend is
# always usable"; backends that depend on an optional CPAN module
# (e.g. Linux::Inotify2) override it to return 0 when that module
# isn't installed.
sub viable { 1 }

# Start / stop hooks. Defaults are no-ops so simple watchers can
# just provide watch + changed_files and skip everything else.
sub start { }
sub stop  { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::ChangeWatcher - Contract for a file-change
watcher the preload reloader consumes.

=head1 DESCRIPTION

A change watcher observes a set of files and reports which ones have
changed since the last C<changed_files> call. The preload reloader
uses exactly one watcher instance per stage; the watcher picks its
backend (inotify, mtime-polling, etc.) without the reloader caring.

Per C<IPC_AND_LOGGERS> section 10.5.0, every preload stage is
responsible for watching the files in its C<%INC> for changes. The
role is deliberately narrow: a viable backend need only know how to
register a file and hand back a list of files that have changed.

=head1 REQUIRED METHODS

=over 4

=item $w->watch($file, $value = 1)

Register a file for watching. The optional C<$value> is either the
literal C<1> (no callback) or a coderef the caller wants invoked
instead of the standard reload path; storage is opaque -- the role
doesn't care about the shape, only that C<changed_files> reports
which watched files have changed.

=item $arrayref = $w->changed_files

Return an arrayref of file paths that have changed since the last
call, or a false value (undef / empty array / 0) when nothing has
changed. Implementations are responsible for any debouncing they
want; the reloader calls C<changed_files> once per tick.

=back

=head1 OPTIONAL METHODS

=over 4

=item $bool = Backend->viable

Feature-detection. Return 0 when the backend cannot run in the
current environment (required CPAN module missing, OS kernel
doesn't support the watch primitive, etc.). Default: 1.

=item $w->start / $w->stop

Lifecycle hooks. Default no-ops.

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
