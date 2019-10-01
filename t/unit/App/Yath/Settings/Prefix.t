use Test2::V0;

__END__

package App::Yath::Settings::Prefix;
use strict;
use warnings;

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
