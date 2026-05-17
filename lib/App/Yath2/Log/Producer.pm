package App::Yath2::Log::Producer;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Object::HashBase qw{
    <id
    <kind
    <parent_id
    <run_id
    <state
    <started_at
    <ended_at
    <artifact_refs
    <log
};

my %VALID_STATE = (missing => 1, partial => 1, sealed  => 1);
my %VALID_KIND  = (run     => 1, job     => 1, service => 1, collector => 1);

sub init {
    my $self = shift;
    croak "'id' is required"              unless defined $self->{+ID};
    croak "'kind' is required"            unless defined $self->{+KIND};
    croak "invalid kind '$self->{+KIND}'" unless $VALID_KIND{$self->{+KIND}};
    my $s = $self->{+STATE} // 'missing';
    croak "invalid state '$s'" unless $VALID_STATE{$s};
    $self->{+STATE} = $s;
    $self->{+ARTIFACT_REFS} //= {};
    return;
}

sub artifact_ref {
    my ($self, $kind) = @_;
    return $self->{+ARTIFACT_REFS}{$kind};
}

sub artifact {
    my ($self, $kind) = @_;
    return unless $self->{+LOG};
    return $self->{+LOG}->artifact_for_producer($self, $kind);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Producer - Base descriptor for a Log producer.

=head1 DESCRIPTION

Carries identity, parentage, kind, state, artifact refs, and timestamps.
Per-kind subclasses (L<App::Yath2::Log::Producer::Run>,
L<App::Yath2::Log::Producer::Job>,
L<App::Yath2::Log::Producer::Service>,
L<App::Yath2::Log::Producer::Collector>) add kind-specific fields.

=head1 VALID VALUES

=head2 kind

C<run>, C<job>, C<service>, C<collector>.

=head2 state

C<missing>, C<partial>, C<sealed>.

=head1 METHODS

=over 4

=item $p->artifact_ref($kind)

Returns the artifact reference of C<$kind> stored in C<artifact_refs>, or
C<undef> if none is present.

=item $p->artifact($kind)

Delegates to the associated Log backend's C<artifact_for_producer> method.
Returns C<undef> if no Log is attached.

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
