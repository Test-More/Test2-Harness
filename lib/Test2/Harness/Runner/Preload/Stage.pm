package Test2::Harness::Runner::Preload::Stage;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    <name
    <frame
    <children
    <pre_fork_callbacks
    <post_fork_callbacks
    <pre_launch_callbacks
    <load_sequence
    <watches
    eager
    reload_remove_check
    reload_inplace_check
};

sub init {
    my $self = shift;

    $self->{+FRAME} //= [caller(1)];

    croak "'name' is a required attribute" unless $self->{+NAME};

    croak "Stage name 'base' is reserved, pick another name"      if $self->{+NAME} eq 'base';
    croak "Stage name 'NOPRELOAD' is reserved, pick another name" if $self->{+NAME} eq 'NOPRELOAD';

    $self->{+CHILDREN} //= [];

    $self->{+PRE_FORK_CALLBACKS}   //= [];
    $self->{+POST_FORK_CALLBACKS}  //= [];
    $self->{+PRE_LAUNCH_CALLBACKS} //= [];

    $self->{+LOAD_SEQUENCE} //= [];
    $self->{+WATCHES} //= {};
}

sub watch {
    my $self = shift;
    my ($file, $callback) = @_;
    croak "The first argument must be a file" unless $file && -f $file;
    croak "The callback argument is required" unless $callback && ref($callback) eq 'CODE';
    croak "There is already a watch on file '$file'" if $self->{+WATCHES}->{$file};

    $self->{+WATCHES}->{$file} = $callback;
    return;
}

sub all_children {
    my $self = shift;

    my @out = @{$self->{+CHILDREN}};

    for (my $i = 0; $i < @out; $i++) {
        my $it = $out[$i];
        push @out => @{$it->children};
    }

    return \@out;
}

sub add_child {
    my $self = shift;
    my ($stage) = @_;
    push @{$self->{+CHILDREN}} => $stage;
}

sub add_pre_fork_callback {
    my $self = shift;
    my ($cb) = @_;
    croak "Callback must be a coderef" unless ref($cb) eq 'CODE';
    push @{$self->{+PRE_FORK_CALLBACKS}} => $cb;
}

sub add_post_fork_callback {
    my $self = shift;
    my ($cb) = @_;
    croak "Callback must be a coderef" unless ref($cb) eq 'CODE';
    push @{$self->{+POST_FORK_CALLBACKS}} => $cb;
}

sub add_pre_launch_callback {
    my $self = shift;
    my ($cb) = @_;
    croak "Callback must be a coderef" unless ref($cb) eq 'CODE';
    push @{$self->{+PRE_LAUNCH_CALLBACKS}} => $cb;
}

sub add_to_load_sequence {
    my $self = shift;

    for my $item (@_) {
        croak "Item '$item' is not a valid preload, must be a module name (scalar) or a coderef"
            unless ref($item) eq 'CODE' || !ref($item);

        push @{$self->{+LOAD_SEQUENCE}} => $item;
    }

    return @_;
}

sub do_pre_fork   { my $self = shift; $_->(@_) for @{$self->{+PRE_FORK_CALLBACKS}} }
sub do_post_fork  { my $self = shift; $_->(@_) for @{$self->{+POST_FORK_CALLBACKS}} }
sub do_pre_launch { my $self = shift; $_->(@_) for @{$self->{+PRE_LAUNCH_CALLBACKS}} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preload::Stage - Abstraction of a preload stage.

=head1 DESCRIPTION

This is an implementation detail. You are not intended to directly use/modify
instances of this class. See L<Test2::Harness::Runner::Preload> for
documentation on how to write a custom preload library.

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
