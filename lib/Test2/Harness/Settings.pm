package Test2::Harness::Settings;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp();
use Scalar::Util();

use Test2::Harness::Settings::Prefix;

sub new {
    my $class = shift;

    my $hash;
    if (@_ == 1) {
        require Test2::Harness::Util::File::JSON;
        my $settings_file = Test2::Harness::Util::File::JSON->new(name => $_[0]);
        $hash = $settings_file->read;
    }
    else {
        $hash = {@_};
    }

    for my $key (keys %$hash) {
        my $val = delete $hash->{$key};

        if (Scalar::Util::blessed($val)) {
            Carp::croak("All prefixes must contain instances of Test2::Harness::Settings::Prefix")
                unless $val->isa('Test2::Harness::Settings::Prefix');

            $hash->{$key} = $val;
            next;
        }

        Carp::croak("All prefixes must be defined as hashes")
            unless ref($val) eq 'HASH';

        $hash->{$key} = Test2::Harness::Settings::Prefix->new(%$val);
    }

    return bless(\$hash, $class);
}

sub define_prefix {
    my $self = shift;
    my ($prefix) = @_;

    return ${$self}->{$prefix} //= Test2::Harness::Settings::Prefix->new;
}

sub check_prefix {
    my $self = shift;
    my ($prefix) = @_;
    return exists(${$self}->{$prefix});
}

sub prefix {
    my $self = shift;
    my ($prefix, @args) = @_;

    Carp::croak("Too many arguments for prefix()") if @args;
    Carp::croak("The '$prefix' prefix is not defined") unless ${$self}->{$prefix};

    return ${$self}->{$prefix};
}

sub build {
    my $self = shift;
    my ($prefix, $class, @args) = @_;

    my $p = $self->prefix($prefix);

    $p->build($class, @args);
}

our $AUTOLOAD;
sub AUTOLOAD {
    my $this = shift;

    my $prefix = $AUTOLOAD;
    $prefix =~ s/^.*:://g;

    return if $prefix eq 'DESTROY';

    Carp::croak("Method $prefix() must be called on a blessed instance") unless ref($this);
    Carp::croak("Too many arguments for $prefix()") if @_;

    $this->prefix($prefix);
}

sub TO_JSON {
    my $self = shift;
    return {%$$self};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Settings - Configuration settings for Test2::Harness.

=head1 DESCRIPTION

This module represents the options provided at the command line. Each option
has a prefix, and each prefix can be accessed from the settings.

=head1 SYNOPSIS

    # You will rarely if ever need to construct settings yourself, usually a
    # component of Test2::Harness will expose them to you.
    my $settings = $thing->settings;

    # All prefixes have a method generated for them via AUTOLOAD
    my $display = $settings->display;

    # You can also use the prefix method
    my $display = $settings->prefix('display');


    # The prefix can be used in a similar way
    my $verbose = $settings->display->verbose;

See L<Test2::Harness::Settings::Prefix> for more details on how to use the prefixes.

=head1 METHODS

Note that any prefix that does not conflict with the predefined methods can be
accessed via AUTOLOAD generating the methods as needed.

=over 4

=item $settings->define_prefix($prefix_name)

This is used to create a prefix.

=item $bool = $settings->check_prefix($prefix_name)

This is used to check if a prefix is defined or not.

=item $prefix = $settings->prefix($prefix_name)

=item $prefix = $settings->$prefix_name

This will retrieve a prefix if it exists. If the prefix is not defined this
will throw an exception. If you are unsure if a prefix exists use
C<$settings->check_prefix($prefix_name)>.

=item $thing = $settings->build($prefix_name, $class, @args)

This will create an instance of C<$class> passing the key/value pairs from the
specified prefix as arguments. Additional arguments can be provided in
C<@args>.

=item $hashref = $settings->TO_JSON()

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
