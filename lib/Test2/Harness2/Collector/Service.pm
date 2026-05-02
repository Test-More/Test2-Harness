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

Two related role flags are passed at construction rather than carried
on dedicated subclasses:

=over 4

=item C<is_run =E<gt> 1>

Used by the run service's interpose collector. Marks the loggers as
belonging to a run-service collector so the role's
C<output_file_basename> rules collapse the common-case
C<service_name == run_id> path down to C<$logdir/runs/E<lt>run_idE<gt>>,
which is where the run's .jsonl and .json belong.

=item C<is_harness_collector =E<gt> 1>

Used by the harness's own top-of-tree interpose collector. With no
C<ipc_parent> and an C<ipc_harness> pointing at this collector's own
child service, the C<collector_exiting> / C<collector_artifacts>
sends would target an already-exiting peer; this flag short-circuits
those self-addressed sends.

=back

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
