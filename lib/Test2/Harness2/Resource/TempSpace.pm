package Test2::Harness2::Resource::TempSpace;
use strict;
use warnings;

# Implementation note: this resource accepts a --utilize percentage; the
# gating mechanism is wired up in a follow-up step.

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec();

use parent 'Test2::Harness2::Resource::Disk';

use Object::HashBase qw{
    <utilize_percent
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource::Utilizer';

sub resource_name { 'temp_space' }

sub init {
    my $self = shift;

    # Auto-fill the disk we monitor with the system temp dir if the
    # caller did not specify a different mount. The base Disk
    # resource expects `mounts` to be a hash of
    # { '/path' => { min_free_mb => $n } }; we register a single
    # entry keyed on the resolved temp dir and inherit the rest of
    # Disk's poll_interval / threshold defaults.
    unless ($self->{mounts} && keys %{$self->{mounts}}) {
        my $tmpdir = File::Spec->tmpdir;
        $self->{mounts} = {$tmpdir => {}};
    }

    $self->SUPER::init();
}

# Utilizer role contract; wired up alongside the disk sampler in a
# follow-up step.
sub set_utilize_percent {
    croak __PACKAGE__ . "::set_utilize_percent is not implemented yet";
}

sub is_temporarily_unavailable {
    croak __PACKAGE__ . "::is_temporarily_unavailable is not implemented yet";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::TempSpace - (STUB) Throttle jobs when the system temp directory fills up.

=head1 STATUS

Stub only. Subclasses L<Test2::Harness2::Resource::Disk> with the
disk to monitor auto-set to L<File::Spec>'s C<tmpdir>. Implements
L<Test2::Harness2::Role::Resource::Utilizer>; both the role's required
methods C<croak> until the disk sampler is wired up.

=head1 DESCRIPTION

Auto-monitors the system temp directory (C<File::Spec-E<gt>tmpdir>),
deferring new assignments when the threshold (the resource's
C<utilize_percent> from C<--utilize> / C<-U>, layered over the
underlying L<Test2::Harness2::Resource::Disk> mount config) is
exceeded.

The intended (not-yet-wired) implementation reuses the
L<Test2::Harness2::Resource::Disk> sampler service to poll C<statvfs>
or C</bin/df>, then layers the utilizer percentage on top of (or in
place of) the parent's C<min_free_mb>-based gate.

=head1 SEE ALSO

L<Test2::Harness2::Resource::Disk> -- the parent stub.

L<Test2::Harness2::Role::Resource::Utilizer> -- the role this
resource consumes.

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
