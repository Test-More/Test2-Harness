package App::Yath2::Role::Renderer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny;

# The renderer contract per IPC_AND_LOGGERS §13.
#
# A renderer is a PASSIVE event consumer. It does not read artifacts
# off disk, it does not query IPC, it does not subscribe to the
# harness bus. Everything it consumes arrives through event_in(),
# which is driven by the command-side artifact-reading layer
# (App::Yath2::ArtifactReader).
#
# Output is free: a renderer may write to a terminal, a file, a
# database, an HTTP endpoint, or pipe through to a downstream
# consumer. The prohibition is only on *reading* inputs from
# anywhere other than its event_in() entry point.
#
# Four lifecycle hooks bracket the event stream:
#
#   start_of_run(%info)   - called once, before the first event_in
#                           for a given run. %info carries run_id
#                           and may carry additional metadata (job
#                           count, mode, timing context, ...).
#   event_in($event)      - called for each event the layer chose to
#                           forward. $event is a hashref in the
#                           Test2::Harness2::Event shape -- see
#                           lib/Test2/Harness2/Event.pm. The layer
#                           may synthesise its own events (short
#                           job-pass/fail summaries, run_complete
#                           aggregates) when no artifacts are
#                           available; those share the same
#                           hashref shape.
#   end_of_run(%summary)  - called once per run, after the last
#                           event_in, with the run's terminal
#                           aggregate (pass_count, fail_count,
#                           duration, per-job verdicts). Match to
#                           the run_complete payload shape in
#                           IPC_AND_LOGGERS §7.
#   shutdown()            - called once, at command tear-down, so
#                           the renderer can flush its output and
#                           release any external resources. Always
#                           called -- even when end_of_run never
#                           fired (e.g. the command aborted before
#                           a run completed).
#
# Each hook has a default no-op implementation. A minimal renderer
# only needs to override event_in.

requires 'event_in';

sub start_of_run { }
sub end_of_run   { }
sub shutdown     { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::Renderer - Passive event-consumer contract for yath renderers.

=head1 SYNOPSIS

    package My::Yath::Renderer;
    use Object::HashBase qw/<io/;
    use Role::Tiny::With;
    with 'App::Yath2::Role::Renderer';

    sub event_in {
        my ($self, $event) = @_;
        # ... render to $self->{+IO} ...
    }

    sub end_of_run {
        my ($self, %summary) = @_;
        printf { $self->{+IO} } "%d passed, %d failed\n",
            $summary{pass_count}, $summary{fail_count};
    }

=head1 DESCRIPTION

Consume this role (via C<Role::Tiny::With>) on classes that render
events produced by the command-side artifact-reading layer. The role
establishes the one-way interface described in C<IPC_AND_LOGGERS §13>:
the renderer receives events, it does not read artifacts or query IPC.

=head1 REQUIRED METHODS

=over 4

=item $renderer->event_in($event)

The single entry point the artifact-reading layer uses to hand
events to the renderer. C<$event> is a hashref in the
L<Test2::Harness2::Event> shape: top-level keys include
C<event_id>, C<stamp>, and C<facet_data>; the layer may add
synthetic events (short per-job pass/fail notifications, a
final C<run_complete> aggregate) whose C<facet_data> carries a
C<harness> facet with the kind-specific slot from
C<IPC_AND_LOGGERS §7>.

=back

=head1 OPTIONAL HOOKS

Each has a default no-op implementation so the caller can
dispatch unconditionally.

=over 4

=item $renderer->start_of_run(%info)

Called once per run, before the first C<event_in>. C<%info>
typically carries at least C<run_id>.

=item $renderer->end_of_run(%summary)

Called once per run, after the last C<event_in>, with the
terminal aggregate (C<pass_count>, C<fail_count>, C<duration>,
per-job verdicts). Matches the shape of a C<run_complete>
message's payload.

=item $renderer->shutdown

Called once at command tear-down. Always fires -- even when
C<end_of_run> did not (e.g. the command aborted mid-run).

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
