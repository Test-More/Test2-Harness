package Test2::Harness2::Reloader::KillRestart;
use strict;
use warnings;

our $VERSION = '2.000011';

# Stateless reloader; provide a minimal new() so consumers can use
# the usual class->new pattern. Object::HashBase with no slots would
# not install new().
sub new {
    my $class = shift;
    return bless {@_}, $class;
}

use Role::Tiny::With;
with 'Test2::Harness2::Role::Reloader';

sub viable { 1 }

# The kill-and-restart reloader never reloads in place. Every file it
# sees comes back as not_reloadable, so the preload resource's reload
# pipeline falls into the branch-pruning path described in
# IPC_AND_LOGGERS section 10.5.1: the affected stage (and its
# descendants) is terminated and the parent re-forks it fresh. Tests
# already launched out of the pruned subtree continue because they
# detach from the stage at launch time.
#
# Used as the terminal entry in the reloader chain: Default first
# (best-effort in-place), KillRestart last (force a restart).
sub reload_module {
    my ($self, $module, $file, $info) = @_;
    return ('not_reloadable', reason => "KillRestart policy: always restart the stage");
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::KillRestart - Fallback reloader that
always triggers a stage restart.

=head1 DESCRIPTION

Per C<IPC_AND_LOGGERS> section 10.5, branch pruning is the
fallback when in-place reload is not possible. The KillRestart
reloader returns C<not_reloadable> for every change, forcing the
preload resource to kill the affected stage's subtree and re-fork
it from its parent. Tests already launched out of the pruned
subtree detach at launch time (section 10.4) so they complete
on their own timeline.

=head1 USAGE

Typically the terminal entry in a reloader chain:

    my @reloaders = (
        Test2::Harness2::Reloader::Default->new,
        Test2::Harness2::Reloader::KillRestart->new,
    );

    for my $reloader (@reloaders) {
        my ($status, %fields) = $reloader->reload_module($mod, $file, $info);
        next if defined $status && $status eq 'not_reloadable';
        return ($status, %fields);
    }

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
