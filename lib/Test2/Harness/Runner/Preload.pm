package Test2::Harness::Runner::Preload;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;

use Test2::Harness::Runner::Preload::Stage();

sub import {
    my $class = shift;
    my $caller = caller;

    my %exports;

    my $instance = $class->new;

    $exports{TEST2_HARNESS_PRELOAD} = sub { $instance };

    $exports{stage} = sub {
        my ($name, $code) = @_;
        my @caller = caller();
        $instance->build_stage(
            name   => $name,
            code   => $code,
            caller => \@caller,
        );
    };

    for my $name (qw/pre_fork pre_fork pre_launch/) {
        my $meth = "add_${name}_callback";
        $exports{$name} = sub {
            croak "No current stage" unless @{$instance->stack};
            my $stage = $instance->stack->[-1];
            $stage->$meth(@_);
        };
    }

    $exports{preload} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->add_to_load_sequence(@_);
    };

    for my $name (keys %exports) {
        no strict 'refs';
        *{"$caller\::$name"} = $exports{$name};
    }
}

use Test2::Harness::Util::HashBase qw{
    <linear
    <stage_list
    <stage_lookup
    <stack
};

sub init {
    my $self = shift;

    $self->{+STAGE_LIST} //= [];
    $self->{+STAGE_LOOKUP} //= {};

    $self->{+STACK} //= [];

    $self->{+LINEAR} //= @{$self->{+STAGE_LIST}} > 1 ? 0 : 1;
}

sub build_stage {
    my $self = shift;
    my %params = @_;

    my $caller = $params{caller} //= [caller()];

    die "A coderef is required at $caller->[1] line $caller->[2].\n"
        unless $params{code};

    my $stage = Test2::Harness::Runner::Preload::Stag->new(
        stage_lookup => $self->{+STAGE_LOOKUP},
        stage_list   => $self->{+STAGE_LOOKUP},
        linear       => $self->{+LINEAR},
        %params,
    );

    my $stack = $self->{+STACK} //= [];
    push @$stack => $stage;

    my $ok = eval { $params{code}->($stage); 1 };
    my $err = $@;

    die "Mangled stack" unless @$stack && $stack->[-1] eq $stage;

    pop @$stack;

    die $err unless $ok;

    if (@$stack) {
        $stack->[-1]->add_child($stage);
    }
    else {
        $self->add_stage($stage, $caller);
    }

    return $stage;
}

sub add_stage {
    my $self = shift;
    my ($stage, $caller) = @_;

    $caller //= [caller()];

    my @all = ($stage, @{$stage->all_children});

    for my $item (@all) {
        my $name = $item->name;

        if (my $existing = $self->{+STAGE_LOOKUP}->{$name}) {
            $caller //= [caller()];
            my $ncaller = $item->frame;
            my $ecaller = $existing->frame;
            die <<"            EOT"
A stage named '$name' was already defined.
  First at  $ecaller->[1] line $ecaller->[2].
  Second at $ncaller->[1] line $ncaller->[2].
  Mixed at  $caller->[1] line $caller->[2].
            EOT
        }

        $self->{+STAGE_LOOKUP}->{$name} = $item;
        $self->{+LINEAR} &= @{$self->{+STAGE_LIST}} <= 1
    }

    push @{$self->{+STAGE_LIST}} => $stage;
    $self->{+LINEAR} &= @{$self->{+STAGE_LIST}} <= 1
}

sub merge {
    my $self = shift;
    my ($merge) = @_;

    my $caller = [caller()];

    $self->{+LINEAR} &= $merge->{+LINEAR};

    for my $stage (@{$merge->{+STAGE_LIST}}) {
        $self->add_stage($stage, $caller);
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preload - DSL for building complex stage-based preload
tools.

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
