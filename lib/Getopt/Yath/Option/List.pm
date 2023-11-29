package Getopt::Yath::Option::List;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util::JSON qw/decode_json/;

use parent 'Getopt::Yath::Option';
use Test2::Harness::Util::HashBase qw/<split_on/;

sub allows_list       { 1 }
sub allows_arg        { 1 }
sub requires_arg      { 1 }
sub allows_default    { 1 }
sub allows_autofill   { 0 }
sub requires_autofill { 0 }

sub notes { (shift->SUPER::notes(), 'Can be specified multiple times') }

sub is_populated { ${$_[1]} && @{${$_[1]}} }

sub get_clear_value {
    my $self = shift;
    return $self->_get___value(CLEAR(), @_) // [];
}

sub get_initial_value {
    my $self = shift;

    my @val;

    my $env = $self->from_env_vars;
    for my $name (@{$env || []}) {
        push @val => $ENV{$name} if defined $ENV{$name};
    }

    return \@val if @val;

    return undef if $self->{+MAYBE};
    return $self->_get___value(INITIALIZE()) // [];
}

sub add_value {
    my $self = shift;
    my ($ref, @val) = @_;
    return unless @val;
    push @{$$ref} => @val;
}

sub normalize_value {
    my $self = shift;
    my (@input) = @_;

    if ($input[0] =~ m/^\s*\[.*\]\s*$/s) {
        my $out;
        local $@;
        unless (eval { local $SIG{__DIE__}; $out = decode_json($input[0]); 1 }) {
            my ($err) = split /[\n\r]+/, $@;
            $err =~ s{at \Q$INC{'Test2/Harness/Util/JSON.pm'}\E line \d+\..*$}{};
            die "Could not decode JSON string: $err\n====\n$input[0]\n====\n";
        }
        return @$out;
    }

    my @output;
    if (my $on = $self->split_on) {
        @output = map { $self->SUPER::normalize_value($_) } map { split($on, $_) } @input;
    }
    else {
        @output = map { $self->SUPER::normalize_value($_) } @input;
    }

    return @output;
}

sub default_long_examples  {
    my $self = shift;
    my %params = @_;

    my $list = $self->SUPER::default_long_examples(%params);
    push @$list => (qq{ '["json","list"]'}, qq{='["json","list"]'});
    return $list;
}

sub default_short_examples {
    my $self = shift;
    my %params = @_;

    my $list = $self->SUPER::default_long_examples(%params);
    push @$list => (qq{ '["json","list"]'}, qq{='["json","list"]'});
    return $list;
}


1;