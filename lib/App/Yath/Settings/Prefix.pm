package App::Yath::Settings::Prefix;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp();
use Test2::Harness::Util();

sub new {
    my $class = shift;
    my $hash = {@_};
    return bless \$hash, $class;
}

sub vivify_field {
    my $self = shift;
    my ($field) = @_;

    return \(${$self}->{$field});
}

sub field : lvalue {
    my $self = shift;
    my ($field, @args) = @_;

    Carp::croak("Too many arguments for field()") if @args > 1;
    Carp::croak("The '$field' field does not exist") unless exists ${$self}->{$field};

    (${$self}->{$field}) = @args if @args;

    return ${$self}->{$field};
}

our $AUTOLOAD;
sub AUTOLOAD : lvalue {
    my $this = shift;

    my $field = $AUTOLOAD;
    $field =~ s/^.*:://g;

    return if $field eq 'DESTROY';

    Carp::croak("Method $field() must be called on a blessed instance") unless ref($this);
    Carp::croak("Too many arguments for $field()") if @_ > 1;

    $this->field($field, @_);
}

sub TO_JSON {
    my $self = shift;
    return {%$$self};
}

sub build {
    my $self = shift;
    my ($class, @args) = @_;

    require(Test2::Harness::Util::mod2file($class));

    return $class->new(%$$self, @args);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Settings::Prefix - Abstraction of a settings section, aka prefix.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
