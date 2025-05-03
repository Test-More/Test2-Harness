package Test2::Harness::Reloader::Inotify2;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use Linux::Inotify2 qw/IN_MODIFY IN_ATTRIB IN_DELETE_SELF IN_MOVE_SELF/;

use Test2::Harness::Util qw/clean_path/;

my $MASK = IN_MODIFY | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF;

use parent 'Test2::Harness::Reloader';
use Test2::Harness::Util::HashBase qw{
    <watcher
};

sub start {
    my $self = shift;

    my $watcher = Linux::Inotify2->new;
    $watcher->blocking(0);
    $self->{+WATCHER} = $watcher;

    return $self->SUPER::start(@_);
}

sub stop {
    my $self = shift;
    delete $self->{+WATCHER};
    return $self->SUPER::stop(@_);
}

sub do_watch {
    my $self = shift;
    my ($file, $val) = @_;

    my $watcher = $self->{+WATCHER} or return;
    $watcher->watch($file, $MASK, sub { $self->notify(@_) });
    return $val;
}

sub changed_files {
    my $self = shift;

    my $watcher = $self->{+WATCHER} // croak "Reloader is not started yet";

    my @out;
    my %seen;
    no warnings 'once';
    local *notify = sub {
        my $self = shift;
        my ($e) = @_;

        my $file = $e->fullname();
        return unless $file;
        next if $seen{$file}++;
        push @out => $file;
    };

    $watcher->poll;

    return \@out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Reloader::Inotify2 - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

