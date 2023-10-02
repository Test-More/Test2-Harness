package Test2::Harness::Runner::DepTracer;
use strict;
use warnings;

use Carp qw/croak/;

our $VERSION = '1.000155';

use Test2::Harness::Util::HashBase qw/
    -_on
    -exclude
    -dep_map
    -loaded
    -my_require
    -real_require
    -_my_inc
    -callbacks
/;

my %DEFAULT_EXCLUDE = (
    'warnings.pm' => 1,
    'strict.pm'   => 1,
);

my $ACTIVE;

sub ACTIVE { $ACTIVE }

sub start {
    my $self = shift;

    croak "There is already an active DepTracer" if $ACTIVE;

    $ACTIVE = $self;

    unshift @INC => $self->my_inc;

    $self->{+_ON} = 1;
}

sub stop {
    my $self = shift;

    croak "DepTracer is not active" unless $ACTIVE;
    croak "Different DepTracer is active" unless "$ACTIVE" eq "$self";
    $ACTIVE = undef;

    $self->{+_ON} = 0;

    my $inc = $self->{+_MY_INC} or return 0;

    @INC = grep { !(ref($_) && $inc == $_) } @INC;
    return 0;
}

sub my_inc {
    my $self = shift;

    return $self->{+_MY_INC} if $self->{+_MY_INC};

    my $exclude = $self->{+EXCLUDE} ||= {%DEFAULT_EXCLUDE};
    my $dep_map = $self->{+DEP_MAP} ||= {};
    my $loaded  = $self->{+LOADED}  ||= {};

    return $self->{+_MY_INC} ||= sub {
        my ($this, $file) = @_;

        return unless $self->{+_ON};
        return unless $file =~ m/^[_a-z]/i;
        return if $exclude->{$file};

        my $loaded_by = $self->loaded_by;
        push @{$dep_map->{$file}} => $loaded_by;
        $loaded->{$file}++;

        return;
    };
}

sub clear_loaded { %{$_[0]->{+LOADED}} = () }

my %REQUIRE_CACHE;

sub add_callbacks {
    my $self = shift;
    my %watch = @_;
    for my $file (keys %watch) {
        my $cb = $watch{$file};
        $self->add_callback($file => $cb);
    }
}

sub add_callback {
    my $self = shift;
    my ($file, $cb) = @_;
    $self->{+LOADED}->{$file}++;
    $self->{+CALLBACKS}->{$file} = $cb;
}

sub init {
    my $self = shift;

    my $exclude = $self->{+EXCLUDE} ||= { %DEFAULT_EXCLUDE };

    my $stash = \%CORE::GLOBAL::;
    # We use a string in the reference below to prevent the glob slot from
    # being auto-vivified by the compiler.
    $self->{+REAL_REQUIRE} = exists $stash->{require} ? \&{'CORE::GLOBAL::require'} : undef;

    $self->{+CALLBACKS} //= {};
    my $dep_map = $self->{+DEP_MAP} ||= {};
    my $loaded  = $self->{+LOADED} ||= {};
    my $inc = $self->my_inc;

    my $require = $self->{+MY_REQUIRE} = sub {
        my ($file) = @_;

        my $loaded_by = $self->loaded_by;

        my $real_require = $self->{+REAL_REQUIRE};
        unless($real_require) {
            my $caller = $loaded_by->[0];
            $real_require = $REQUIRE_CACHE{$caller} ||= eval "package $caller; sub { CORE::require(\$_[0]) }" or die $@;
        }

        goto &$real_require unless $self->{+_ON};

        if ($file =~ m/^[_a-z]/i) {
            unless ($exclude->{$file}) {
                push @{$dep_map->{$file}} => $loaded_by;
                $loaded->{$file}++;
            }
        }

        if (!ref($INC[0]) || $INC[0] != $inc) {
            @INC = (
                $inc,
                grep { !(ref($_) && $inc == $_) } @INC,
            );
        }

        local @INC = @INC[1 .. $#INC];

        $real_require->(@_);
    };

    {
        no strict 'refs';
        no warnings 'redefine';
        *{'CORE::GLOBAL::require'} = $require;
    }
}

sub loaded_by {
    my $level = 1;

    while(my @caller = caller($level++)) {
        next if $caller[0] eq __PACKAGE__;

        return [$caller[0], $caller[1]];
    }

    return ['', ''];
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::DepTracer - Tool for tracing module dependencies as
they are loaded.

=head1 DESCRIPTION

This tool is used by Test2::Harness to build a graph of dependancies which can
then be used to blacklist modified modules (and anything thatuses them) when
they change under a preloaded runner.

=head1 SYNOPSIS

    use Test2::Harness::Runner::DepTracer;

    my $dt = Test2::Harness::Runner::DepTracer->new();

    $dt->start();

    require Some::Thing;

    # You can always check for and retrieve an active DepTrace this way:
    my $dt_reference = Test2::Harness::Runner::DepTracer->ACTIVE;

    $dt->stop();

    my $dep_map = $dt->dep_map;

    my $loaded_by = $dep_map->{'Some/Thing.pm'};
    print "Some::Thing was directly or indirectly loaded by:\n" . join("\n" => @$loaded_by) . "\n";

=head1 ATTRIBUTES

These can be specified at construction, and will be populated during use.

=over 4

=item $hashref = $dt->exclude

A hashref of files/modules to exclude from dep tracking. By default C<strict>
and C<warnings> are excluded.

=item $hashref = $dt->dep_map

Every file which is loaded while the tool is started will have an entry in this
hash, each value is an array of all files which loaded the key file directly or
indirectly.

=item $hashref = $dt->loaded

How many times each file was directly loaded.

=back

=head1 METHODS

=over 4

=item $dt->start

Start tracking modules which are loaded.

=item $dt->stop

Stop tracking moduels that are loaded.

=back

=head1 CLASS METHODS

=over 4

=item $dt_or_undef = Test2::Harness::Runner::DepTracer->ACTIVE();

Get the currently active DepTracer, if any.

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
