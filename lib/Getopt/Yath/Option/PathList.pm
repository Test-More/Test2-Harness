package Getopt::Yath::Option::PathList;
use strict;
use warnings;

our $VERSION = '2.000005';

use parent 'Getopt::Yath::Option::List';
use Test2::Harness::Util::HashBase;

sub normalize_value {
    my $self = shift;
    my (@input) = @_;

    my @out;
    for my $val (@input) {
        if ($val =~ m/\*/) {
            push @out => $self->SUPER::normalize_value($_) for glob($val);
        }
        else {
            push @out => $self->SUPER::normalize_value($val);
        }
    }

    return @out;
}

sub default_long_examples  {
    my $self = shift;
    my %params = @_;

    my $list = $self->SUPER::default_long_examples(%params);
    push @$list => (qq{ '*.*'}, qq{='*.*'});
    return $list;
}

sub default_short_examples {
    my $self = shift;
    my %params = @_;

    my $list = $self->SUPER::default_long_examples(%params);
    push @$list => (qq{ '*.*'}, qq{='*.*'});
    return $list;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Option::PathList - FIXME

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

