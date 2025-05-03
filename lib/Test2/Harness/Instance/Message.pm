package Test2::Harness::Instance::Message;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Event;

use Test2::Harness::Util::HashBase qw{
    ipc_meta
    connection
    terminate
    run_complete
    +event
};

sub init {
    my $self = shift;
}

sub event {
    my $self = shift;

    my $event = $self->{+EVENT} or return undef;
    return $event if $event && blessed($event) && $event->isa('Test2::Harness::Event');

    $event = decode_json($event) unless ref($event);

    return $self->{+EVENT} = Test2::Harness::Event->new(%$event);
}

sub TO_JSON {
    my $self = shift;
    my $type = blessed($self);

    return { %$self, class => $type };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Instance::Message - FIXME

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

