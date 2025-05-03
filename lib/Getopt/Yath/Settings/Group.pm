package Getopt::Yath::Settings::Group;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp();

sub new {
    my $class = shift;
    my $self = (@_ != 1) ? { @_ } : $_[0];

    return bless($self, $class);
}

sub all { return %{$_[0]} }

sub check_option { exists($_[0]->{$_[1]}) ? 1 : 0 }

sub option :lvalue {
    my $self = shift;
    my ($option, @vals) = @_;

    Carp::confess("Too many arguments for option()") if @vals > 1;
    Carp::confess("The '$option' option does not exist") unless exists $self->{$option};

    ($self->{$option}) = @vals if @vals;

    return $self->{$option};
}

sub create_option {
    my $self = shift;
    my ($name, $val) = @_;

    $self->{$name} = $val;

    return $self->{$name};
}

sub option_ref {
    my $self = shift;
    my ($name, $create) = @_;

    Carp::confess("The '$name' option does not exist") unless $create || exists $self->{$name};

    return \($self->{$name});
}

sub delete_option {
    my $self = shift;
    my ($name) = @_;

    delete $self->{$name};
}

sub remove_option {
    my $self = shift;
    my ($name) = @_;
    delete ${$self}->{$name};
}

our $AUTOLOAD;
sub AUTOLOAD : lvalue {
    my $this = shift;

    my $option = $AUTOLOAD;
    $option =~ s/^.*:://g;

    return if $option eq 'DESTROY';

    Carp::confess("Method $option() must be called on a blessed instance") unless ref($this);

    $this->option($option, @_);
}

sub TO_JSON {
    my $self = shift;
    return {%$self};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Settings::Group - FIXME

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

