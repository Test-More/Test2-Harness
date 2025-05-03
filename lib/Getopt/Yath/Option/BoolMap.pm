package Getopt::Yath::Option::BoolMap;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;

use parent 'Getopt::Yath::Option::Map';
use Test2::Harness::Util::HashBase qw/+pattern +requires_arg +custom_matches/;

sub allows_list       { 1 }
sub allows_default    { 1 }
sub allows_arg        { 1 }
sub allows_autofill   { 0 }
sub requires_autofill { 0 }

sub notes { (shift->SUPER::notes(), 'Can be specified multiple times') }

sub requires_arg { $_[0]->{+REQUIRES_ARG} ? 1 : 0 }

sub init {
    my $self = shift;
    $self->SUPER::init(@_);

    croak "A 'pattern' is required" unless $self->{+PATTERN};

    return $self;
}

sub no_arg_value { $_[0]->field, 1 }

sub pattern {
    my $self = shift;

    my $append = $self->{+PATTERN};
    return qr/^--(no-)?$append$/;
}

sub default_long_examples  {
    my $self = shift;
    my $out = $self->SUPER::default_long_examples(@_);
    push @$out => $self->pattern;
    return $out;
}

sub default_short_examples {
    my $self = shift;
    my $out = $self->SUPER::default_short_examples(@_);
    push @$out => $self->pattern;
    return $out;
}

sub custom_matches {
    my $self = shift;
    my $pattern = $self->pattern;

    return sub {
        my ($input, $state) = @_;

        return $self->{+CUSTOM_MATCHES}->($self, @_)
            if $self->{+CUSTOM_MATCHES};

        return unless $input =~ $pattern;
        my ($no, $key) = ($1, $2);
        return ($self, 1, [$key => $no ? 0 : 1]);
    };
}

sub doc_forms {
    my $self = shift;
    my %params = @_;

    my ($forms, $no_forms) = $self->SUPER::doc_forms(%params);

    my $inner = "" . $self->{+PATTERN};
    $inner =~ s{^\Q(?^:\E}{};
    $inner =~ s{\)$}{};

    return ($forms, $no_forms, ["/^--(no-)?$inner\$/"]);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Option::BoolMap - FIXME

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

