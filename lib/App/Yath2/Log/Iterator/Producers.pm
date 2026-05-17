package App::Yath2::Log::Iterator::Producers;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Object::HashBase qw{
    <next_cb
    +_done
};

sub init {
    my $self = shift;
    croak "'next_cb' is required and must be a CODE reference"
        unless ref($self->{+NEXT_CB}) eq 'CODE';
    $self->{+_DONE} = 0;
    return;
}

sub next {
    my $self = shift;
    return undef if $self->{+_DONE};
    my $d = $self->{+NEXT_CB}->();
    unless (defined $d) {
        $self->{+_DONE} = 1;
        return undef;
    }
    return $d;
}

sub all {
    my $self = shift;
    my @out;
    while (defined(my $d = $self->next)) {
        push @out, $d;
    }
    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Iterator::Producers - Lazy iterator over producer descriptors.

=head1 DESCRIPTION

Wraps a callback that returns the next producer descriptor or C<undef>
at EOF. The Log backend supplies the callback; consumers (renderers,
concluders) drive the iterator via C<next> or C<all>.

EOF is sticky: once the callback returns C<undef>, subsequent C<next>
calls also return C<undef> without re-invoking the callback.

=head1 ATTRIBUTES

=over 4

=item $iter->next_cb

Read-only. The CODE reference supplied at construction. Called by
C<next> to fetch the next descriptor. Must return a producer descriptor
object or C<undef> to signal end-of-sequence.

=back

=head1 METHODS

=over 4

=item $descriptor = $iter->next

Returns the next producer descriptor, or C<undef> at end-of-sequence.
After returning C<undef> once, all further calls return C<undef> without
invoking the callback again (sticky EOF).

=item @descriptors = $iter->all

Drains the iterator and returns all remaining descriptors in order.

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

See L<http://dev.perl.org/licenses/>

=cut
