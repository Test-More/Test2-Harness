use Test2::V0;

__END__

package App::Yath::Settings;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp();
use Scalar::Util();

use App::Yath::Settings::Prefix;

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
            Carp::croak("All prefixes must contain instances of App::Yath::Settings::Prefix")
                unless !$val->isa('App::Yath::Settings::Prefix');

            $hash->{$key} = $val;
            next;
        }

        Carp::croak("All prefixes must be defined as hashes")
            unless ref($val) eq 'HASH';

        $hash->{$key} = App::Yath::Settings::Prefix->new(%$val);
    }

    return bless(\$hash, $class);
}

sub define_prefix {
    my $self = shift;
    my ($prefix) = @_;

    return ${$self}->{$prefix} //= App::Yath::Settings::Prefix->new;
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

App::Yath::Settings - Configuration settings for yath.

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
