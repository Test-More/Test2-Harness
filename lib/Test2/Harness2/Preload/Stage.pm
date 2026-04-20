package Test2::Harness2::Preload::Stage;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();

use Object::HashBase qw{
    <name
    <frame
    <children
    <pre_fork_callbacks
    <post_fork_callbacks
    <pre_launch_callbacks
    <load_sequence
    <watches
    eager
    reload_inplace_check
};

sub init {
    my $self = shift;

    $self->{+FRAME} //= [caller(1)];

    croak "'name' is a required attribute" unless $self->{+NAME};

    croak "Stage name 'base' is reserved, pick another name"
        if $self->{+NAME} eq 'base';

    croak "Stage name 'NOPRELOAD' is reserved, pick another name"
        if $self->{+NAME} eq 'NOPRELOAD';

    $self->{+CHILDREN} //= [];

    $self->{+PRE_FORK_CALLBACKS}   //= [];
    $self->{+POST_FORK_CALLBACKS}  //= [];
    $self->{+PRE_LAUNCH_CALLBACKS} //= [];

    $self->{+LOAD_SEQUENCE} //= [];
    $self->{+WATCHES}       //= {};
}

sub watch {
    my $self = shift;
    my ($file, $callback) = @_;

    croak "The first argument must be a file"
        unless $file && -f $file;

    croak "The callback argument is required"
        unless $callback && ref($callback) eq 'CODE';

    $file = File::Spec->rel2abs($file);

    croak "There is already a watch on file '$file'"
        if $self->{+WATCHES}->{$file};

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

Test2::Harness2::Preload::Stage - Value object describing a single preload
stage.

=head1 DESCRIPTION

A C<Stage> is built by the L<Test2::Harness2::Preload> DSL and consumed by
the preloader service tree. Each stage carries a name, an ordered list of
modules/coderefs to load, a set of file-watches, three callback lists
(C<pre_fork>, C<post_fork>, C<pre_launch>), and an optional tree of child
stages.

This class is pure data. The stage does not spawn processes, load modules,
or install watches on its own; the preloader service tree does that based
on the data held here.

=head1 ATTRIBUTES

=over 4

=item name (required)

Stage name. Case-sensitive. The names C<base> and C<NOPRELOAD> are reserved.

=item frame

C<[caller]> frame recorded at construction time, used for diagnostics when
two stages collide on name.

=item children

Arrayref of child C<Stage> objects (nested stages).

=item pre_fork_callbacks / post_fork_callbacks / pre_launch_callbacks

Arrayrefs of coderefs to run at the corresponding lifecycle point when the
stage launches a test.

=item load_sequence

Arrayref of module-name strings and coderefs, in the order the stage should
process them during startup.

=item watches

Hashref keyed by absolute file path, value is a coderef to run when the
file changes (in place of the normal reload process).

=item eager

Boolean. If true, tests destined for nested stages may run in this stage
while the nested stage is still loading.

=item reload_inplace_check

Optional coderef consulted by the reloader before attempting in-place
module reload.

=back

=head1 METHODS

=over 4

=item @cb = $stage->do_pre_fork(@args)

=item @cb = $stage->do_post_fork(@args)

=item @cb = $stage->do_pre_launch(@args)

Invoke each callback in the corresponding list with C<@args>.

=item $stage->add_child($substage)

Nest another stage under this one.

=item $stages = $stage->all_children

Return all descendants as a flattened arrayref (depth-first).

=item $stage->add_pre_fork_callback($cb)

=item $stage->add_post_fork_callback($cb)

=item $stage->add_pre_launch_callback($cb)

Register a lifecycle callback.

=item $stage->add_to_load_sequence(@items)

Append modules / coderefs to the load sequence.

=item $stage->watch($file, $cb)

Register a file watch with a custom reload callback. C<$file> is resolved
to an absolute path. A second watch on the same file is an error.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
