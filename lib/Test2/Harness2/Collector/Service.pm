package Test2::Harness2::Collector::Service;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use parent 'Test2::Harness2::Collector';

# Service-interpose collectors identify themselves by the bus name of
# the service they are interposed on -- ipc_parent, which every such
# collector has. The only site that legitimately has no ipc_parent is
# the harness's own interpose collector (the harness is the top of
# the tree); that call site MUST pass bus_id explicitly instead of
# relying on this builder.
sub _build_collector_bus_id {
    my $self = shift;

    my $ipc_parent = $self->ipc_parent
        or croak "Service collector requires 'ipc_parent' to derive bus_id (pass bus_id explicitly for the top-of-tree harness interpose)";

    return $self->_compose_bus_id($ipc_parent);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Service - Collector subclass for service-interpose use.

=head1 DESCRIPTION

Extends L<Test2::Harness2::Collector> with the service-specific bus
id: C<collector:E<lt>ipc_parentE<gt>> (optionally suffixed with
C<:run_id>).

A service collector has no auditor (the base class's no-op
C<auditor> / C<_normalize_auditor> / C<_instantiate_auditor>
defaults apply).

Callers whose service has no C<ipc_parent> -- the harness's own
top-of-tree interpose collector -- must pass C<bus_id> explicitly
instead of relying on the builder.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut
