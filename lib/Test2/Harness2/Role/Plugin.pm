package Test2::Harness2::Role::Plugin;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny;

# Harness-side plugin hooks. A plugin for Test2::Harness2 is either a
# class name or a blessed instance; every hook is optional and callers
# use $plugin->can('hook') && $plugin->hook(...) to dispatch. The
# stubs below exist so a consumer that does nothing still round-trips
# cleanly -- they return the documented "no answer" value for each
# hook (undef for data hooks, nothing for callback hooks).
#
# Hooks that make sense only at the CLI layer (option contributions,
# finder ordering, renderer selection, end-of-run summary output)
# live on App::Yath2::Role::Plugin instead. This role is the subset
# that Test2::Harness2 itself invokes and therefore the subset a
# plugin can rely on without pulling App::Yath2 in.

# Periodic tick driven by the harness event loop. %args carries a
# 'type' key whose value is one of the dispatch sites ("instance",
# "run", ...). Plugins that want to do timer-style bookkeeping hang
# it off this hook.
sub tick { }

# Called when the scheduler queues a run, immediately after the run
# object has been constructed. Receives the Test2::Harness2::Run
# instance. Useful for per-run setup that needs the run object
# itself (its id, its job list, its settings).
sub run_queued { }

# Called when every job in a run has reached a terminal state and
# the run itself is about to be reported as complete.
sub run_complete { }

# Called when a run is aborted (e.g. halt-on-fail, user ctrl-c)
# rather than finishing normally. Receives the run object and a
# reason string suitable for logging.
sub run_halted { }

# Instance-level hooks. "Instance" here means the longer-lived
# wrapper around a harness process that drives one or more runs;
# plugins use these to attach per-harness state (e.g. connecting to
# an external service once and tearing it down once, regardless of
# how many runs pass through). The three hooks fire in the
# predictable setup / ... / teardown / finalize order.
sub instance_setup    { }
sub instance_teardown { }
sub instance_finalize { }

# Test discovery hooks. Plugins that synthesize tests (generated
# files, virtual test names) or rewrite the default search list
# implement these. munge_search receives the user-provided list and
# a default-search fallback; munge_files receives the
# Test2::Harness2::TestFile objects after discovery and may mutate
# them in place; claim_file is an early-bird hook that lets a
# plugin declare ownership of a specific path before the default
# finder does anything with it.
sub munge_search { }
sub munge_files  { }
sub claim_file   { undef }

# Scheduling-data hooks. The scheduler walks the plugin list in
# order and takes the first non-undef answer from duration_data and
# coverage_data. post_process_coverage_tests runs after every
# plugin has had a chance to contribute coverage data, so plugins
# that only want to deduplicate or re-order the merged list
# implement it without implementing coverage_data itself.
sub duration_data               { undef }
sub coverage_data               { undef }
sub post_process_coverage_tests { }

# Change-tracking hooks. changed_files is additive: every plugin's
# list is merged. changed_diff is first-wins: whichever plugin
# answers first owns the diff. Both return empty by default so a
# plugin that only implements one side does not accidentally clear
# the other.
sub changed_files { () }
sub changed_diff  { () }

# Persistent-runner startup/teardown. setup fires once when a
# persistent runner comes up; teardown fires once when the runner
# shuts down. Neither fires per-run.
sub setup    { }
sub teardown { }

# Bare-minimum serialization hook. The default returns a stringified
# form (class name for classes, stringified ref for instances) which
# is enough to reference a plugin in JSON logs without pulling its
# full state in.
sub TO_JSON { ref($_[0]) || "$_[0]" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Plugin - Harness-side plugin hook surface.

=head1 DESCRIPTION

Consume this role (via C<Role::Tiny::With>) on classes that need to
react to a L<Test2::Harness2> run without pulling in anything from
C<App::Yath2>. The role declares a set of optional hooks; each one
has a no-op default so a bare consumer is a working (if uninteresting)
plugin. Consumers override only the hooks they care about.

For the CLI-layer hook surface (options, finders, renderers) see
L<App::Yath2::Role::Plugin>, which consumes this role and adds the
CLI-only hooks on top.

=head1 HOOKS

See the inline comments in the source for the authoritative list.
At a glance the hooks fall into four groups:

=over 4

=item B<Run lifecycle>

C<tick>, C<run_queued>, C<run_complete>, C<run_halted>

=item B<Instance lifecycle>

C<instance_setup>, C<instance_teardown>, C<instance_finalize>,
C<setup>, C<teardown>

=item B<Discovery>

C<munge_search>, C<munge_files>, C<claim_file>

=item B<Scheduling data>

C<duration_data>, C<coverage_data>, C<post_process_coverage_tests>,
C<changed_files>, C<changed_diff>

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>.

=cut
