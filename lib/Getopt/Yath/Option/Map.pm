package Getopt::Yath::Option::Map;
use strict;
use warnings;

our $VERSION = '2.000005';

use Test2::Harness::Util::JSON qw/decode_json/;

use parent 'Getopt::Yath::Option';
use Test2::Harness::Util::HashBase qw/<split_on <key_on/;

sub allows_list       { 1 }
sub allows_default    { 1 }
sub allows_arg        { 1 }
sub requires_arg      { 1 }
sub allows_autofill   { 0 }
sub requires_autofill { 0 }

sub notes { (shift->SUPER::notes(), 'Can be specified multiple times') }

sub _example_append {
    my $self = shift;
    my ($params, @prefixes) = @_;

    return unless $self->allows_list;

    my $groups = $params->{groups} // {};

    my @out;

    for my $prefix (@prefixes) {
        for my $group (sort keys %$groups) {
            push @out => "${prefix}${group} KEY1 VAL KEY2 ${group} VAL1 VAL2 ... $groups->{$group} ... $groups->{$group}";
        }
    }

    return @out;
}

sub default_long_examples  {
    my $self = shift;
    my %params = @_;

    my @append = $self->_example_append(\%params, ' ', '=');

    return [' key=val', '=key=val', qq[ '{"json":"hash"}'], qq[='{"json":"hash"}'], @append];
}

sub default_short_examples {
    my $self = shift;
    my %params = @_;

    my @append = $self->_example_append(\%params, '', ' ', '=');

    return [' key=val', 'key=value', '=key=val', qq[ '{"json":"hash"}'], qq[='{"json":"hash"}'], @append];
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+KEY_ON} //= '=';
}

sub is_populated { ${$_[1]} && keys %{${$_[1]}} }

sub get_initial_value {
    my $self = shift;

    my %val;

    my $env = $self->from_env_vars;
    for my $name (@{$env || []}) {
        $val{$name} = $ENV{$name} if defined $ENV{$name};
    }

    return \%val if keys %val;

    return undef if $self->{+MAYBE};

    return $self->_get___value(INITIALIZE()) // {};
}

sub get_clear_value {
    my $self = shift;
    return $self->_get___value(CLEAR(), @_) // {};
}

sub add_value {
    my $self = shift;
    my ($ref, %vals) = @_;

    return unless keys %vals;

    $$ref //= {};

    %{$$ref} = (
        %{$$ref},
        %vals,
    );
}

sub normalize_value {
    my $self = shift;
    my (@input) = @_;

    return $self->SUPER::normalize_value(@input) if @input > 1;

    if ($input[0] =~ m/^\s*\{.*\}\s*$/s) {
        my $out;
        local $@;
        unless (eval { local $SIG{__DIE__}; $out = decode_json($input[0]); 1 }) {
            my ($err) = split /[\n\r]+/, $@;
            $err =~ s{at \Q$INC{'Test2/Harness/Util/JSON.pm'}\E line \d+\..*$}{};
            die "Could not decode JSON string: $err\n====\n$input[0]\n====\n";
        }
        return %$out;
    }

    my @split;
    if (my $on = $self->split_on) {
        @split = grep { length($_) } map { split($on, $_) } @input;
    }
    else {
        @split = @input;
    }

    my $key_on = $self->key_on // '=';
    my %output = map { my ($k, $v) = split($key_on, $_, 2); $self->SUPER::normalize_value($k, $v) } @split;

    return %output;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Option::Map - FIXME

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

