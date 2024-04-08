package Getopt::Yath::Settings;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath::Settings::Group;
use Carp();

sub new {
    my $class = shift;
    my $self = @_ == 1 ? $_[0] : { @_ };

    bless($self, $class);

    Getopt::Yath::Settings::Group->new($_) for values %$self;

    return $self;
}

sub maybe {
    my $self = shift;
    my ($group, $opt, $default) = @_;

    return $default unless $self->check_group($group);

    my $g = $self->$group;

    return $default unless $g->check_option($opt);

    return $g->$opt // $default;
}

sub check_group { $_[0]->{$_[1]} ? 1 : 0 }

sub group {
    my $self = shift;
    my ($group, $vivify) = @_;

    return $self->{$group} if $self->{$group};

    return $self->{$group} = Getopt::Yath::Settings::Group->new()
        if $vivify;

    Carp::croak("The '$group' group is not defined");
}

sub create_group {
    my $self = shift;
    my ($name, @vals) = @_;

    return $self->{$name} = Getopt::Yath::Settings::Group->new(@vals == 1 ? $vals[0] : { @vals });
}

sub delete_group {
    my $self = shift;
    my ($name) = @_;

    delete $self->{$name};
}

our $AUTOLOAD;
sub AUTOLOAD {
    my $this = shift;

    my $group = $AUTOLOAD;
    $group =~ s/^.*:://g;

    return if $group eq 'DESTROY';

    Carp::croak("Method $group() must be called on a blessed instance") unless ref($this);

    $this->group($group);
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

Getopt::Yath::Settings - FIXME

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

