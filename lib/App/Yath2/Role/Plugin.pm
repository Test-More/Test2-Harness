package App::Yath2::Role::Plugin;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny;
use Role::Tiny::With;

# The CLI-side plugin role consumes the harness-side role wholesale.
# This keeps the hook inheritance direction clear: a plugin written
# against App::Yath2::Role::Plugin can be used anywhere the harness
# role is expected, but the reverse is not true -- harness-only
# plugins never pull App::Yath2 in.
with 'Test2::Harness2::Role::Plugin';

# CLI-only plugin hooks. Each one is invoked by App::Yath2 or
# App::Yath2::Command::* code; callers dispatch conditionally
# (can() checks or method_modifiers) so every hook below has a
# sensible "no answer" default.

# Initial per-run hook dispatched when the command layer begins
# driving a run. Fires once per invocation of `yath test` (or the
# equivalent), before any test is launched. Useful for hooking into
# a live rendering surface or opening a per-run external resource
# that the plugin will tear down in client_teardown.
sub client_setup { }

# Mirror of client_setup that fires after the run finishes and
# before the command exits. Plugins that returned an event arrayref
# from this hook in old yath kept that behaviour available via the
# return value, which the dispatcher may forward to the renderer.
sub client_teardown { }

# Final per-invocation hook, dispatched as the very last step
# before the command exits. Distinct from client_teardown so that
# summary-style output can run after every plugin has had a chance
# to drain its own state in teardown.
sub client_finalize { }

# File-ordering hook. The sort_files_2 signature matches the old
# App::Yath2::Plugin hook: (settings => ..., files => \@unsorted)
# returning a sorted list. sort_files (single-arg @files) is the
# deprecated predecessor. Neither is called unless implemented by
# a specific plugin, so the defaults are empty.
sub sort_files_2 { }
sub sort_files   { }

# Extract reproducible argument values from settings so that a
# plugin can reconstruct its command-line arguments after the fact
# (for replay / rerun / audit purposes). Default returns an empty
# list.
sub args_from_settings { () }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::Plugin - CLI-side plugin hook surface.

=head1 DESCRIPTION

Consume this role (via C<Role::Tiny::With>) on classes that need to
participate in the yath command line -- contributing options, shaping
test ordering, or running setup/teardown around a C<yath test>
invocation. This role consumes L<Test2::Harness2::Role::Plugin>, so a
plugin written against it also satisfies the harness-side contract
and can be passed directly to L<Test2::Harness2>.

=head1 HOOKS

In addition to every hook declared on L<Test2::Harness2::Role::Plugin>,
this role provides:

=over 4

=item B<Per-invocation lifecycle>

C<client_setup>, C<client_teardown>, C<client_finalize>

=item B<File ordering>

C<sort_files_2>, C<sort_files> (deprecated alias)

=item B<Audit / replay>

C<args_from_settings>

=back

Renderer-specific hooks (C<annotate_event>, C<finish>, C<finalize>
for end-of-run summary output) are deferred to the renderer stage
(stage 12) and intentionally not declared here.

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
