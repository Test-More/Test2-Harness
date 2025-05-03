package Getopt::Yath::Option::Count;
use strict;
use warnings;

use Carp qw/croak/;

our $VERSION = '2.000005';

use parent 'Getopt::Yath::Option';
use Test2::Harness::Util::HashBase;

sub allows_shortval   { 0 }
sub allows_arg        { 1 }
sub requires_arg      { 0 }
sub allows_autofill   { 0 }
sub requires_autofill { 0 }
sub is_populated      { 1 }    # Always populated

sub no_arg_value { () }

sub clear_field { ${$_[1]} = 0 }    # --no-count

# Autofill should be 0 if not specified
sub get_autofill_value { $_[0]->SUPER::get_autofill_value() // 0 }

sub default_long_examples  {my $self = shift; ['', '=COUNT'] }
sub default_short_examples {my $self = shift; ['', $self->short, ($self->short x 2) . '..', '=COUNT'] }

sub notes { (shift->SUPER::notes(), 'Can be specified multiple times, counter bumps each time it is used.') }

# --count
# --count=5
sub add_value {
    my $self = shift;
    my ($ref, @val) = @_;

    # Explicit value set
    return $$ref = $val[0] if @val;

    # Make sure we have a sane start
    $$ref //= $self->get_autofill_value;

    # Bump by one
    return ${$ref}++;
}

sub can_set_env   { 1 }

sub get_env_value {
    my $opt = shift;
    my ($var, $ref) = @_;

    return $$ref unless $var =~ m/^!/;
    return $ref ? 0 : 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Option::Count - FIXME

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

