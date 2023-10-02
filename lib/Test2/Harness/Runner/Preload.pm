package Test2::Harness::Runner::Preload;
use strict;
use warnings;

our $VERSION = '1.000155';

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

    $exports{eager} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->set_eager(1);
    };

    $exports{default} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        my $name = $stage->name;
        $instance->set_default_stage($name);
    };

    $exports{file_stage} = sub {
        my ($callback) = @_;
        my @caller = caller();
        croak "'file_stage' cannot be used under a stage" if @{$instance->stack};
        $instance->add_file_stage(\@caller, $callback);
    };

    for my $name (qw/pre_fork post_fork pre_launch/) {
        my $meth = "add_${name}_callback";
        $exports{$name} = sub {
            croak "No current stage" unless @{$instance->stack};
            my $stage = $instance->stack->[-1];
            $stage->$meth(@_);
        };
    }

    $exports{watch} = sub {
        if (@{$instance->stack}) {
            my $stage = $instance->stack->[-1];
            return $stage->watch(@_);
        }

        if ($INC{'Test2/Harness/Runner/DepTracer.pm'}) {
            if (my $active = Test2::Harness::Runner::DepTracer->ACTIVE) {
                return $active->add_callback(@_);
            }
        }

        croak "No current stage, and no active deptracer";
    };

    $exports{preload} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->add_to_load_sequence(@_);
    };

    $exports{reload_remove_check} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->set_reload_remove_check(@_);
    };

    $exports{reload_inplace_check} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->set_reload_inplace_check(@_);
    };

    for my $name (keys %exports) {
        no strict 'refs';
        *{"$caller\::$name"} = $exports{$name};
    }
}

use Test2::Harness::Util::HashBase qw{
    <stage_list
    <stage_lookup
    <stack
    +default_stage
    +file_stage
};

sub init {
    my $self = shift;

    $self->{+STAGE_LIST} //= [];
    $self->{+STAGE_LOOKUP} //= {};

    $self->{+STACK} //= [];

    $self->{+FILE_STAGE} //= [];
}

sub build_stage {
    my $self = shift;
    my %params = @_;

    my $caller = $params{caller} //= [caller()];

    die "A coderef is required at $caller->[1] line $caller->[2].\n"
        unless $params{code};

    my $stage = Test2::Harness::Runner::Preload::Stage->new(
        stage_lookup => $self->{+STAGE_LOOKUP},
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

    push @{$self->{+FILE_STAGE}} => @{$merge->{+FILE_STAGE}};

    $self->{+DEFAULT_STAGE} //= $merge->default_stage;
}

sub add_file_stage {
    my $self = shift;
    my ($caller, $code) = @_;

    croak "Caller must be defined and an array" unless $caller && ref($caller) eq 'ARRAY';
    croak "Code must be defined and a coderef"  unless $code   && ref($code) eq 'CODE';

    push @{$self->{+FILE_STAGE}} => [$caller, $code];
}

sub file_stage {
    my $self = shift;
    my ($file) = @_;

    for my $cb (@{$self->{+FILE_STAGE}}) {
        my ($caller, $code) = @$cb;
        my $stage = $code->($file) or next;

        die "file_stage callback returned invalid stage: $stage at $caller->[1] line $caller->[2].\n"
            unless $self->{+STAGE_LOOKUP}->{$stage};

        return $stage;
    }

    return;
}

sub default_stage {
    my $self = shift;
    return $self->{+DEFAULT_STAGE} if $self->{+DEFAULT_STAGE};
    return $self->{+STAGE_LIST}->[0];
}

sub set_default_stage {
    my $self = shift;
    my ($name) = @_;

    croak "Default stage already set to $self->{+DEFAULT_STAGE}" if $self->{+DEFAULT_STAGE};
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

Test2::Harness::Runner::Preload - DSL for building complex stage-based preload
tools.

=head1 DESCRIPTION

L<Test2::Harness> allows you to preload libraries for a performance boost. This
module provides tools that let you go beyond that and build a more complex
preload. In addition you can build multiple preload I<stages>, each stage will
be its own process and tests can run from a specific stage. This allows for
multiple different preload states from which to run tests.

=head1 SYNOPSIS

=head2 USING YOUR PRELOAD

The C<-P> or C<--preload> options work for custom preload modules just as they
do regular modules. Yath will know the difference and act accordingly.

    yath test -PMy::Preload

=head2 WRITING YOUR PRELOAD

    package My::Preload;
    use strict;
    use warnings;

    # This imports several useful tools, and puts the necessary meta-data in
    # your package to identify it as a special preload.
    use Test2::Harness::Runner::Preload;

    # You must specify at least one stage.
    stage Moose => sub {
        # Preload can be called multiple times, and can load multiple modules
        # per call. Order is preserved.
        preload 'Moose', 'Moose::Role';
        preload 'Scalar::Util', 'List::Util';

        # preload can also be given a sub if you have some custom code to run
        # at a specific point in the load order
        preload sub {
            # Do something before loading Try::Tiny
            ...
        };

        preload 'Try::Tiny';

        # Tell the runner to watch this file for changes, if it does change run
        # the sub instead of the usual reload process. This lets you reload
        # configs and other non-perl files, or allows you to use a custom
        # reload sub for perl files.
        watch 'path/to/file' => sub { ... };

        # You can also use watch inside preload subs:
        preload sub {
            watch 'path/to/file' => sub { ... };
        };

        # In app code you can add watches dynamically when applicable:
        preload sub {
            ... # inside app code

            if ($INC{'Test2/Harness/Runner/DepTracer.pm'}) {
                if (my $active = Test2::Harness::Runner::DepTracer->ACTIVE) {
                    $active->add_callback('path/to/file' => sub { ... });
                }
            }

            ...
        };

        # Eager means tests from nested stages can be run in this stage as
        # well, this is useful if the nested stage takes a long time to load as
        # it allows yath to start running tests sooner instead of waiting for
        # the stage to finish loading. Once the nested stage is loaded tests
        # intended for it will start running from it instead.
        eager();

        # default means this stage is the one to use if the test does not
        # specify a stage.
        default();

        # These are hooks that let you run arbitrary code at specific points in
        # the process. pre_fork happens just before forking to run a test.
        # post_fork happens just after forking for a test. pre_launch happens
        # as late as possible before the test starts executing (post fork,
        # after $0 and other special state are reset).
        pre_fork sub { ... };
        post_fork sub { ... };
        pre_launch sub { ... };

        # Stages can be nested, nested ones build off the previous stage, but
        # are in a forked process to avoid contaminating the parent.
        stage Types => sub {
            preload 'MooseX::Types';
        };
    };

    # Alternative stage that loads Moo instead of Moose
    stage Moo => sub {
        preload 'Moo';

        ...
    };

=head2 HARNESS DIRECTIVES IN PRELOADS

If you use a staged preload, and the --reload option, you can add 'CHURN'
directives to files in order to only reload sections you are working on. This
is particularly useful when a file cannot be reloaded in full, or when doing so
is expensive. You can wrap subroutines in the churn directives to have yath
reload only those subroutines.

    sub do_not_reload_this { ... {

    # HARNESS-CHURN-START

    sub reload_this_one {
        ...
    }

    sub reload_this_one_too {
        ...
    }

    # HARNESS-CHURN-STOP

    sub this_is_not_reloaded { ... }

You can put as many churn sections you want in as many preloaded modules as you
want. If a change is detected then only the churn sections will be reloaded.
The churn sections are reloaded by taking the source between the start and stop
markers, and running them in an eval like this:

    eval <<EOT
    package MODULE_FROM_FILENAME;
    use strict;
    use warnings;
    no warnings 'redefine';
    #line $line_number $file
    $YOUR_CODE
    ;1;
    EOT

In most cases this is sufficient to replace the old sub with the new one. If
the automatically determined package is not correct you can add a C<package
FOO;> statement inside the markers. If the strict/warnings settings are not to
your specifications you can add overrides inside the markers. Any valid perl
code can go into the markers.

B<CAVEATS:> Be aware they do not have their original scope, and that can lead
to problems if you are not paying attention. Variables outside your markers are
not accessible, and lexical variables put inside your markers will be "new" on
each reload, this can cause confusion if you have lexicals used by multiple
subs where some are inside churn blocks and others are not, so best not to do
that. Package variables work a bit better, but any assignment lines are re-run.
So C<our $FOO;> is fine (it does not change the value if it is set) but
C<our $FOO = ...> will reset the var on each reload.

=head1 EXPORTS

=over 4

=item $meta = TEST2_HARNESS_PRELOAD()

=item $meta = $class->TEST2_HARNESS_PRELOAD()

This export provides the meta object, which is an instance of this class. This
method being present is how Test2::Harness differentiates between a regular
module and a special preload library.

=item stage NAME => sub { ... }

This creates a new stage with the given C<NAME>, and then runs the coderef with
the new stage set as the I<active> one upon which the other function here will
operate. Once the coderef returns the I<active> stage is cleared.

You may nest stages by calling this function again inside the codeblock.

B<NOTE:> stage names B<ARE> case sensitive. This can be confusing when you
consider that most harness directives are all-caps. In the following case the
stage requested by the test and the stage defined in
the library are NOT the same.

In a test file:

    # HARNESS-STAGE-FOO

In a preload library:

    stage foo { ... }

Harness directives are all-caps, however the user data portion need not be,
this is fine:

    # HARNESS-STAGE-foo

However it is very easy to make the mistake of thinking it is case insensitive.
It is also easy to assume the 'foo' part of the harness directive must be all
caps. In many cases it is smart to make your stage names all-caps.

=item preload $module_name

=item preload @module_names

=item preload sub { ... }

This B<MUST> be called inside a C<stage()> builder coderef.

This adds modules to the list of libraries to preload. Order is preserved. You
can also add coderefs to execute arbitrary code between module loads.

The coderef is called with no arguments, and its return is ignored.

=item eager()

This B<MUST> be called inside a C<stage()> builder coderef.

This marks the I<active> stage as being I<eager>. An eager stage will start
running tests for nested stages if it finds itself with no tests of its own to
run before the nested stage can finish loading. The idea here is to avoid
unused test slots when possible allowing for tests to complete sooner.

=item default()

This B<MUST> be called inside a C<stage()> builder coderef.

This B<MUST> be called only once across C<ALL> stages in a given library.

If multiple preload libraries are loaded then the I<first> default set (based
on load order) will be the default, others will notbe honored.

=item $stage_name = file_stage($test_file)

This is optional. If defined this callback will have a chance to look at all
files that are going to be run and assign them a stage. This may return undef
or an empty list if it does not have a stage to assign.

If multiple preload libraries define file_stage callbacks they will be called
in order, the first one to return a stage name will win.

If no file_stage callbacks provide a stage for a file then any harness
directives declaring a stage will be honored. If no stage is ever assigned then
the test will be run int he default stage.

=item pre_fork sub { ... }

This B<MUST> be called inside a C<stage()> builder coderef.

Add a callback to be run just before the preload-stage process forks to run the
test. Note that any state changes here can effect future tests to be run.

=item post_fork sub { ... }

This B<MUST> be called inside a C<stage()> builder coderef.

Add a callback to be run just after the preload-stage process forks to run the
test. This is run as early as possible, things like C<$0> may not be set
properly yet.

=item pre_launch sub { ... }

This B<MUST> be called inside a C<stage()> builder coderef.

Add a callback to be run just before control of the test process is turned over
to the test file itself. This is run as late as possible, so things like C<$0>
should be set properly.

=back

=head1 META-OBJECT

This class is also the meta-object used to construct a preload library. The
methods are left undocumented as this is an implementation detail and you are
not intended to directly use this object.

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
