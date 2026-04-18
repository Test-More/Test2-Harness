package Test2::Harness2::Preload;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;

use Test2::Harness2::Preload::Stage();

use Object::HashBase qw{
    <stage_list
    <stage_lookup
    <stack
    +default_stage
};

sub import {
    my $class  = shift;
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
        my $stage = $instance->stack->[-1];
        $stage->set_eager(1);
    };

    $exports{default} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $instance->set_default_stage($stage->name);
    };

    for my $name (qw/pre_fork post_fork pre_launch/) {
        my $method = "add_${name}_callback";
        $exports{$name} = sub {
            croak "No current stage" unless @{$instance->stack};
            my $stage = $instance->stack->[-1];
            $stage->$method(@_);
        };
    }

    $exports{watch} = sub {
        if (@{$instance->stack}) {
            my $stage = $instance->stack->[-1];
            return $stage->watch(@_);
        }

        if ($INC{'Test2/Harness2/Reloader.pm'}) {
            if (my $active = Test2::Harness2::Reloader->ACTIVE) {
                return $active->watch(@_);
            }
        }

        if (my $stage = $Test2::Harness2::Preloader::Stage::ACTIVE) {
            return $stage->watch(@_);
        }

        croak "$$ $0 - No current stage, and no active reloader";
    };

    $exports{preload} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->add_to_load_sequence(@_);
    };

    $exports{reload_inplace_check} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->set_reload_inplace_check(@_);
    };

    for my $name (keys %exports) {
        no strict 'refs';
        *{"${caller}::${name}"} = $exports{$name};
    }
}

sub init {
    my $self = shift;

    $self->{+STAGE_LIST}   //= [];
    $self->{+STAGE_LOOKUP} //= {};
    $self->{+STACK}        //= [];
}

sub build_stage {
    my $self   = shift;
    my %params = @_;

    my $caller = $params{caller} //= [caller()];

    die "A coderef is required at $caller->[1] line $caller->[2].\n"
        unless $params{code};

    my $stage = Test2::Harness2::Preload::Stage->new(
        %params,
    );

    my $stack = $self->{+STACK} //= [];
    push @$stack => $stage;

    my $ok  = eval { $params{code}->($stage); 1 };
    my $err = $@;

    die "Mangled stack" unless @$stack && $stack->[-1] == $stage;

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

    for my $stage (@{$merge->{+STAGE_LIST}}) {
        $self->add_stage($stage, $caller);
    }

    $self->{+DEFAULT_STAGE} //= $merge->default_stage;
}

sub add_file_stage { confess "deprecated, use a plugin to assign stages to tests" }
sub file_stage     { confess "deprecated, use a plugin to assign stages to tests" }

sub default_stage {
    my $self = shift;
    return $self->{+DEFAULT_STAGE} if $self->{+DEFAULT_STAGE};
    my $first = $self->{+STAGE_LIST}->[0] or return undef;
    return $first->name;
}

sub set_default_stage {
    my $self = shift;
    my ($name) = @_;

    croak "Default stage already set to $self->{+DEFAULT_STAGE}"
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

Test2::Harness2::Preload - DSL for building stage-based preload libraries.

=head1 DESCRIPTION

L<Test2::Harness2> can preload Perl modules once in a long-lived process and
then fork tests from that process for a performance boost. This module
provides a DSL for building complex multi-stage preload configurations,
where each stage is a separate long-lived process with its own module set.
Tests may declare which stage to run under via C<HARNESS-STAGE-NAME>
directives (directive scanning is handled elsewhere).

The DSL surface is preserved from the 2.0 draft in C<old/>:

    use Test2::Harness2::Preload;

    stage Moose => sub {
        preload 'Moose', 'Moose::Role';
        preload 'Scalar::Util', 'List::Util';

        preload sub { ... };                   # ordered arbitrary code
        preload 'Try::Tiny';

        watch 'path/to/file' => sub { ... };   # custom reload callback

        eager();                               # tests bound for nested
                                               # stages may run here too
        default();                             # use when no stage given

        pre_fork   sub { ... };
        post_fork  sub { ... };
        pre_launch sub { ... };

        stage Types => sub { preload 'MooseX::Types' };
    };

    stage Moo => sub { preload 'Moo' };

=head1 SYNOPSIS

=head2 USING YOUR PRELOAD

The C<--preload>/C<-P> option on C<yath> accepts any module name. Modules
that have C<use Test2::Harness2::Preload> in them are detected via the
presence of the C<TEST2_HARNESS_PRELOAD> sub; they are loaded into the base
preloader service and their stage tree is materialized. Modules without
that marker are loaded as plain preloads into the base preloader.

=head2 WRITING YOUR PRELOAD

See L</DESCRIPTION> above for a canonical example. Notes:

=over 4

=item * C<stage> may be nested. A nested stage inherits everything loaded
in the outer stage.

=item * C<preload> may be called with module names (loaded in order) or with
a coderef (run in order, return value ignored). Mix freely.

=item * C<watch> registers a file for reload-triggering. Outside a C<stage>
block it falls back to L<Test2::Harness2::Reloader>'s active instance, if
one is running, so application code can add watches dynamically.

=item * C<eager()> marks the surrounding stage as eager. If the service
tree finds itself with no tests for the current stage while a nested stage
is still loading, it will run nested-stage tests in the eager parent
instead.

=item * C<default()> nominates the surrounding stage as the default. Only
one default per preload library is permitted; the first C<default()> across
all preload libraries wins.

=back

=head2 HARNESS DIRECTIVES IN PRELOADS

If you use a staged preload and the C<--reload> option, you may annotate
sections of preloaded modules for targeted reload:

    # HARNESS-CHURN-START

    sub reload_this_one {
        ...
    }

    # HARNESS-CHURN-STOP

When a change to the file is detected, only the marked sections are
re-eval'd rather than reloading the whole module. See
L<Test2::Harness2::Reloader> for the full mechanics.

=head1 EXPORTS

=over 4

=item $meta = TEST2_HARNESS_PRELOAD()

Marker sub added to every preload library. The harness uses its presence to
distinguish a DSL preload from a plain module. Returns the meta-object
(this class).

=item stage NAME => sub { ... }

Create a new stage with the given name and run the coderef with the stage
set as the active one, so other DSL calls affect it.

=item preload $module_or_cb, ...

Add a module to load, or a coderef to run, at this stage. Order is
preserved.

=item eager()

Mark the active stage as eager.

=item default()

Nominate the active stage as the default.

=item pre_fork  { ... }

=item post_fork { ... }

=item pre_launch { ... }

Register lifecycle callbacks. C<pre_fork> runs just before the stage forks
to launch a test; C<post_fork> runs in the child immediately after fork;
C<pre_launch> runs in the child just before control is handed to the test
file.

=item watch $file => sub { ... }

Register a file watch with a custom reload callback. Callable inside a
stage builder, inside a C<preload> sub, or from within already-loaded app
code via the active L<Test2::Harness2::Reloader>.

=item reload_inplace_check sub { ... }

Override the default predicate the reloader consults before attempting
in-place module reload for this stage.

=back

=head1 META OBJECT

This class is also the meta-object for a preload library. The attributes
and methods below are documented for reference but not intended as a
public user API.

=over 4

=item $list = $meta->stage_list

Arrayref of top-level stages.

=item $hash = $meta->stage_lookup

Hashref of all stages keyed by name.

=item $name = $meta->default_stage

Name of the default stage. If none was nominated, returns the name of the
first stage added.

=item $meta->set_default_stage($name)

Nominate the default stage. Errors if a default is already set.

=item $stages = $meta->eager_stages

Hashref of C<stage_name => [child_names]> for every eager stage.

=item $meta->merge($other_meta)

Merge another preload library's stages into this one.

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
