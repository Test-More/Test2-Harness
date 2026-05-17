package App::Yath2::Log::Producer::Service;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Log::Producer';

sub init {
    my $self = shift;
    $self->{+App::Yath2::Log::Producer::KIND} //= 'service';
    $self->SUPER::init();
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Producer::Service - Service producer descriptor.

=head1 DESCRIPTION

Extends L<App::Yath2::Log::Producer> with no additional fields. Defaults
C<kind> to C<'service'>.

A service may be global (no C<parent_id> or C<run_id>) or run-scoped (both
C<parent_id> and C<run_id> set to the owning run's id).

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
