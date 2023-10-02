package Test2::Harness::Settings::Prefix;
use strict;
use warnings;

our $VERSION = '1.000155';

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

sub check_field {
    my $self = shift;
    my ($field) = @_;

    return exists ${$self}->{$field};
}

sub field : lvalue {
    my $self = shift;
    my ($field, @args) = @_;

    Carp::croak("Too many arguments for field()") if @args > 1;
    Carp::croak("The '$field' field does not exist") unless exists ${$self}->{$field};

    (${$self}->{$field}) = @args if @args;

    return ${$self}->{$field};
}

sub remove_field {
    my $self = shift;
    my ($field) = @_;
    delete ${$self}->{$field};
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

Test2::Harness::Settings::Prefix - Abstraction of a settings category, aka prefix.

=head1 DESCRIPTION

This class represents a settings category (prefix).

=head1 SYNOPSIS

    # You will rarely if ever need to construct settings yourself, usually a
    # component of Test2::Harness will expose them to you.
    my $settings = $thing->settings;
    my $display = $settings->display;

    # Once you have your prefix you can read data from it:
    my $verbose = $display->verbose;

    # If you dislike autoload methods you can use the 'field' method:
    my $verbose = $display->field('verbose');

    # You can also change values:
    $display->field(verbose => 1);

    # You can also use the autoloaded method as an lvalue, but this breaks on
    # perls older than 5.16, so it is not used internally, and you should only
    # use it if you know you will never need an older perl:
    $display->verbose = 1;

=head1 METHODS

Note that any field that does not conflict with the predefined methods can be
accessed via AUTOLOAD generating the methods as needed.

=over 4

=item $scalar_ref = $prefix->vivify_field($field_name)

This will force a field into existance. It returns a scalar reference to the
field which can be used to set the value:

    my $vref = $display->vivify_field('verbose');    # Create or find field
    ${$vref} = 1;                                    # set verbosity to 1

=item $bool = $prefix->check_field($field_name)

Check if a field is defined or not.

=item $val = $prefix->field($field_name)

=item $val = $prefix->$field_name

=item $prefix->field($field_name, $val)

=item $prefix->$field_name = $val

Retrieve or set the value of the specified field. This will throw an exception
if the field does not exist.

B<Note>: The lvalue form C<< $prefix->$field_name = $val >> breaks on perls
older then 5.16.

=item $thing = $prefix->build($class, @args)

This will create an instance of C<$class> passing the key/value pairs from the
prefix as arguments. Additional arguments can be provided in C<@args>.

=item $hashref = $prefix->TO_JSON()

This method allows settings to be serialized into JSON.

=back

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
