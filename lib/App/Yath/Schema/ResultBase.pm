package App::Yath::Schema::ResultBase;
use strict;
use warnings;

our $VERSION = '2.000003';

use parent 'DBIx::Class::Core';

*get_all_fields = __PACKAGE__->can('get_inflated_columns');

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;
    return \%cols;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::ResultBase - FIXME

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

