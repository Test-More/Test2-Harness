package Test2::Harness2::Reloader::Inotify2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Linux::Inotify2 qw/IN_MODIFY IN_ATTRIB IN_DELETE_SELF IN_MOVE_SELF/;

use Test2::Harness2::Util qw/clean_path/;

my $MASK = IN_MODIFY | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF;

use parent 'Test2::Harness2::Reloader';
use Object::HashBase qw{
    <watcher
    <_pending
};

sub start {
    my $self = shift;

    my $watcher = Linux::Inotify2->new;
    $watcher->blocking(0);
    $self->{+WATCHER}  = $watcher;
    $self->{+_PENDING} = {};

    return $self->SUPER::start(@_);
}

sub stop {
    my $self = shift;
    delete $self->{+WATCHER};
    delete $self->{+_PENDING};
    return $self->SUPER::stop(@_);
}

sub do_watch {
    my $self = shift;
    my ($file, $val) = @_;

    my $watcher = $self->{+WATCHER} or return;
    $watcher->watch($file, $MASK, sub {
        my ($e) = @_;
        my $fn = $e->fullname;
        $self->{+_PENDING}->{$fn} = 1 if defined $fn;
    });
    return $val;
}

sub changed_files {
    my $self = shift;

    my $watcher = $self->{+WATCHER}
        // croak "Reloader is not started yet";

    $watcher->poll;

    my $pending = $self->{+_PENDING} //= {};
    return [] unless keys %$pending;

    my @out = sort keys %$pending;
    %$pending = ();

    return \@out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::Inotify2 - Linux inotify backend for the preload
reloader.

=head1 DESCRIPTION

Subscribes to C<IN_MODIFY>, C<IN_ATTRIB>, C<IN_DELETE_SELF>, and
C<IN_MOVE_SELF> events via L<Linux::Inotify2>. The watch callbacks feed a
per-poll pending set; C<changed_files> flushes that set and returns the
affected paths in sorted order.

See L<Test2::Harness2::Reloader> for the public API and attributes.

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
