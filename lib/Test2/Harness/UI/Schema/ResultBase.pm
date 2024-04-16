package Test2::Harness::UI::Schema::ResultBase;
use strict;
use warnings;

use base 'DBIx::Class::Core';

sub get_all_fields {
    my $self = shift;
    my @fields = $self->result_source->columns;
    return ( map {($_ => $self->$_)} @fields );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Schema::ResultBase - FIXME

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

