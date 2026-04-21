package Test2::Harness2::Role::ResourceService;
use strict;
use warnings;

our $VERSION = '2.000011';

use POSIX ();

use Role::Tiny;

with 'IPC::Manager::Role::Service';

# Whether a resource service wants to be auto-restarted when it exits
# before the host shuts down. Default is false: a clean exit is
# accepted and an unexpected exit flips the owning resource to
# permanent_broken. Services that are meant to stay up for the
# lifetime of their host override this to return true.
sub restartable { 0 }

# Default spawn: fork, and in the child run the IPC::Manager service
# loop to completion, then _exit. Returns the child pid in the
# parent. Consumers with more involved lifecycles (per-service log
# file, pgroup setup, post_fork redirection, ...) override this.
sub spawn {
    my $self = shift;

    my $pid = fork // die "fork: $!";
    return $pid if $pid;

    $self->set_pid($$);
    my $exit = $self->run // 0;
    POSIX::_exit($exit);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::ResourceService - Role for resource-owned supervised
subprocesses.

=head1 DESCRIPTION

Resources that need a supervised subprocess (a shared-state coordinator,
an external daemon, etc.) return a list of
C<[$service_class, @construction_params]> tuples from their
C<services> method. Each C<$service_class> must consume this role.

This role composes L<IPC::Manager::Role::Service> so every resource
service participates in the same event loop, signal handling, and
request / response protocol as the harness's own services. It adds a
single new accessor, L</restartable>, that the
L<Test2::Harness2::Role::ResourceServiceHost> consults when a service
exits to decide whether to re-spawn it.

=head1 PROVIDED METHODS

=over 4

=item $bool = $service->restartable

Default: C<0>. Override to C<1> in services that should be
auto-restarted when they exit before the host shuts down. A
non-restartable service that exits flips its owning resource to
C<permanent_broken>; a restartable service is re-spawned subject to
the host's restart-spiral protection.

=item $pid = $service->spawn

Default implementation: C<fork>, call C<set_pid> in the child, run the
service loop, and C<POSIX::_exit>. Returns the child pid in the
parent. Consumers that need extra child-side setup (reopening the
service's log file, redirecting stdio, pgroup changes, ...) override
this.

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
