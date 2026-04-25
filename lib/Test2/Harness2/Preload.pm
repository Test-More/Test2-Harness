package Test2::Harness2::Preload;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Test2::Harness2::Preload::Stage();

sub import {
    my $class = shift;
    my $caller = caller;

    my $instance = $class->new;

    my %exports;

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

    $exports{eager} = sub {
        croak "No current stage" unless @{$instance->stack};
        $instance->stack->[-1]->set_eager(1);
    };

    $exports{default} = sub {
        croak "No current stage" unless @{$instance->stack};
        $instance->set_default_stage($instance->stack->[-1]->name);
    };

    for my $hook (qw/pre_fork post_fork pre_launch/) {
        my $meth = "add_${hook}_callback";
        $exports{$hook} = sub {
            croak "No current stage" unless @{$instance->stack};
            $instance->stack->[-1]->$meth(@_);
        };
    }

    $exports{watch} = sub {
        croak "No current stage" unless @{$instance->stack};
        $instance->stack->[-1]->watch(@_);
    };

    $exports{preload} = sub {
        croak "No current stage" unless @{$instance->stack};
        $instance->stack->[-1]->add_to_load_sequence(@_);
    };

    $exports{reload_inplace_check} = sub {
        croak "No current stage" unless @{$instance->stack};
        $instance->stack->[-1]->set_reload_inplace_check(@_);
    };

    for my $name (keys %exports) {
        no strict 'refs';
        *{"${caller}::${name}"} = $exports{$name};
    }
}

use Object::HashBase qw{
    <stage_list
    <stage_lookup
    <stack
    +default_stage
};

sub init {
    my $self = shift;

    $self->{+STAGE_LIST}   //= [];
    $self->{+STAGE_LOOKUP} //= {};
    $self->{+STACK}        //= [];
}

sub build_stage {
    my $self = shift;
    my %params = @_;

    my $caller = $params{caller} //= [caller()];

    die "A coderef is required at $caller->[1] line $caller->[2].\n"
        unless $params{code};

    my $stage = Test2::Harness2::Preload::Stage->new(
        stage_lookup => $self->{+STAGE_LOOKUP},
        %params,
    );

    my $stack = $self->{+STACK};
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
    }

    push @{$self->{+STAGE_LIST}} => $stage;
}

sub merge {
    my $self = shift;
    my ($merge) = @_;

    my $caller = [caller()];

    $self->add_stage($_, $caller) for @{$merge->{+STAGE_LIST}};

    $self->{+DEFAULT_STAGE} //= $merge->default_stage;
}

sub default_stage {
    my $self = shift;
    return $self->{+DEFAULT_STAGE} if $self->{+DEFAULT_STAGE};
    return $self->{+STAGE_LIST}[0];
}

sub set_default_stage {
    my $self = shift;
    my ($name) = @_;

    croak "Default stage already set to '$self->{+DEFAULT_STAGE}'"
        if $self->{+DEFAULT_STAGE};

    $self->{+DEFAULT_STAGE} = $name;
}

sub eager_stages {
    my $self = shift;

    my %eager;

    for my $root (@{$self->{+STAGE_LIST}}) {
        for my $stage ($root, @{$root->all_children}) {
            next unless $stage->eager;
            $eager{$stage->name} = [map { $_->name } @{$stage->all_children}];
        }
    }

    return \%eager;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload - DSL for building complex stage-based preload tools.

=head1 DESCRIPTION

L<Test2::Harness2> allows you to preload libraries for a performance boost.
This module provides tools to go further and build a more complex preload with
multiple I<stages>: each stage is its own process, and tests can be routed to a
specific stage. This allows for multiple preload states from which to run tests.

=head1 SYNOPSIS

    package My::Preload;
    use strict;
    use warnings;

    use Test2::Harness2::Preload;

    stage Moose => sub {
        preload 'Moose', 'Moose::Role';

        eager();     # run child-stage tests here while child loads
        default();   # use this stage when none is specified

        pre_fork  sub { ... };
        post_fork sub { ... };
        pre_launch sub { ... };

        stage Types => sub {
            preload 'MooseX::Types';
        };
    };

=head1 EXPORTS

=over 4

=item TEST2_HARNESS_PRELOAD()

Returns the meta-object (instance of this class). Its presence is how
Test2::Harness2 distinguishes a preload library from a plain module.

=item stage NAME => sub { ... }

Creates a stage. Stages can be nested.

=item preload @modules_or_coderefs

Adds to the stage's load sequence.

=item eager()

Marks the active stage as eager.

=item default()

Designates the active stage as the default.

=item pre_fork sub { ... }

=item post_fork sub { ... }

=item pre_launch sub { ... }

Lifecycle callbacks around the test-process fork.

=item watch $file => sub { ... }

Register a file to watch for changes (requires a reload handler).

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
