package Test2::Harness2::Resource::Preload;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Object::HashBase qw{
    <name
    <modules
    <scope
    <run
    <is_role_consumer
    <reloader_class
    <reloader_args
    <preferred_preload
    +_usable
    &Test2::Harness2::Role::Resource
};

sub init {
    my $self = shift;

    croak "'name' is a required attribute"
        unless defined $self->{+NAME} && length $self->{+NAME};
    croak "'modules' is a required attribute (arrayref, may be empty)"
        unless defined $self->{+MODULES} && ref($self->{+MODULES}) eq 'ARRAY';

    $self->{+SCOPE}            //= 'global';
    $self->{+IS_ROLE_CONSUMER} //= 0;
    $self->{+_USABLE}            = 0;

    croak "'scope' must be 'global' or 'run'"
        unless $self->{+SCOPE} eq 'global' || $self->{+SCOPE} eq 'run';
    # `scope='run'` without `run` is allowed at construction so the
    # harness can rehydrate per-run preload specs over IPC before the
    # Run object exists. set_run() binds the Run before the Resource
    # is consulted by services() or status() (called at scheduler
    # dispatch time, after Run::from_files has returned).
}

# Bind the Run object after construction. Used by the harness to
# attach per-run preloads rehydrated from a queue_test_run payload
# (where the Run does not yet exist at Resource construction time).
sub set_run {
    my ($self, $run) = @_;
    croak "set_run requires a Run object" unless ref $run;
    croak "set_run only valid for scope='run' (got '$self->{+SCOPE}')"
        unless $self->{+SCOPE} eq 'run';
    $self->{+RUN} = $run;
    return;
}

sub resource_name { 'preload:' . $_[0]->{+NAME} }

# CLI-side option parsing. Resource::Preload is rarely built directly
# from `-R Test2::Harness2::Resource::Preload=...` (subclasses are the
# common shape) but still accepts a name= / from= / scope= shape for
# symmetry with the rest of the Resource:: tree and so a subclass can
# delegate to SUPER::parse_options without reinventing it. The
# important entry is `from=NAME`, which maps to preferred_preload and
# wires this Preload's PreloadService to spawn from another live
# PreloadService named NAME instead of forking standalone.
sub inline_key_prefixes { [qw/from scope/] }

# CLI surface plus every programmatic constructor slot. The harness's
# queue_test_run handler builds per-run resources from `[class, k, v,
# ...]` recipes (see App::Yath2::Util::IPC + Test2::Harness2.pm
# queue_test_run handler), and dispatches through parse_options when
# the class provides one. Any slot the constructor requires must
# appear here, or the recipe's kwargs are silently dropped and `new()`
# croaks on the missing attribute.
my %OPTION_KEYS = map { $_ => 1 } qw{
    name from scope preferred_preload
    modules is_role_consumer
    reloader_class reloader_args
    run
};

sub parse_options {
    my ($class, @args) = @_;

    my %out;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        if ($class->is_unknown_kv_arg($arg, $i + 1 < @args)) {
            $out{$arg} = $args[$i + 1] if exists $OPTION_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::Preload: undef positional entry" unless defined $arg;
        croak "Resource::Preload: ref positional entry" if ref $arg;

        if ($arg =~ m{\Aname=(.+)\z}) {
            $out{name} = $1;
        }
        elsif ($arg =~ m{\Afrom=(.+)\z}) {
            $out{preferred_preload} = $1;
        }
        elsif ($arg =~ m{\Ascope=(.+)\z}) {
            $out{scope} = $1;
        }
        else {
            croak "Resource::Preload: unrecognised entry '$arg'";
        }

        $i += 1;
    }

    return %out;
}

# Routing decision lives in the PreloadRouter's resolver
# (resolve_for_job), NOT in the scheduler's normal needs-this-
# resource walk. Returning 0 here keeps _evaluate_resources_for from
# selecting a preload on its own; the scheduler injects the resolved
# Resource::Preload alongside the rest of the assigned resources after
# the resolver picks one.
sub needed { 0 }

# Always available -- the yes/no decision is "is the service ready",
# which is_usable answers. No slot accounting.
sub available { 1 }

# Pure markers; the assignment IS routing, not slot consumption. No
# env vars set.
sub assign  { return 1 }
sub release { return 1 }

sub status {
    my $self = shift;
    return {
        name              => $self->{+NAME},
        scope             => $self->{+SCOPE},
        usable            => $self->{+_USABLE} ? 1 : 0,
        broken            => $self->{+BROKEN} ? 1 : 0,
        permanent_broken  => $self->{+PERMANENT_BROKEN} ? 1 : 0,
        is_role_consumer  => $self->{+IS_ROLE_CONSUMER} ? 1 : 0,
        modules           => [@{$self->{+MODULES}}],
        ($self->{+SCOPE} eq 'run' && ref($self->{+RUN})
            ? (run_id => $self->{+RUN}->run_id)
            : ()),
    };
}

# Override the role default. The role returns true unless something
# is wrong; for preload we additionally require the service to have
# signalled ready. The service is considered "not yet ready" until
# its preload_ready IPC arrives, even with no broken flags set.
sub is_usable {
    my $self = shift;
    return 0 if $self->{+BROKEN};
    return 0 if $self->{+PERMANENT_BROKEN};
    return $self->{+_USABLE} ? 1 : 0;
}

# State transitions driven by harness side in response to preload_*
# IPC events. mark_ready is the only way out of transient broken;
# permanent_broken is sticky (no cleanup path) so a per-run
# preload_ready can never clear a global preload's permanent_broken
# flag (and vice versa). See AI_DOCS/2026-05-10-preload-rework-design.md
# section 5.
sub mark_ready {
    my $self = shift;
    return if $self->{+PERMANENT_BROKEN};
    $self->{+_USABLE} = 1;
    $self->{+BROKEN}  = 0;
}

sub mark_unusable {
    my $self = shift;
    $self->{+_USABLE} = 0;
}

sub mark_broken {
    my $self = shift;
    $self->{+BROKEN}  = 1;
    $self->{+_USABLE} = 0;
}

sub mark_permanent_broken {
    my $self = shift;
    $self->{+BROKEN}           = 1;
    $self->{+PERMANENT_BROKEN} = 1;
    $self->{+_USABLE}          = 0;
}

# Preload does not support pause semantics; override the role's
# slot-setting defaults with no-ops.
sub mark_paused  { }
sub mark_resumed { }

# The Resource hosts one PreloadService process. The
# ResourceServiceHost role on the harness picks this up and calls
# its standard spawn pipeline; the service registers in RUN_PIDS
# under the appropriate scope/run.
sub services {
    my $self = shift;

    # Re-exec the preload service via a fresh perl with the boot module
    # loaded. stay_in_begin=1 makes IPC::Manager::Service::State::import
    # run the service loop synchronously at BEGIN time of the spawned
    # perl's -e snippet. That keeps the entry-script parser paused
    # while the service is running, which is the only state in which
    # goto::file can usefully install a source filter -- specifically
    # the filter PreloadService::run installs in the test grandchild
    # after a longjump out of the service loop.
    #
    # @INC is propagated as -I flags on the exec command so the freshly
    # exec'd perl can find the harness modules + every CPAN dep the
    # parent has already located. PERL5LIB would work too but -I avoids
    # interaction with whatever the user's shell has set.
    my @inc = grep { defined && length } @INC;
    my @cmd = map  { "-I$_" } @inc;

    my @args = (
        name             => $self->{+NAME},
        modules          => [@{$self->{+MODULES}}],
        scope            => $self->{+SCOPE},
        is_role_consumer => $self->{+IS_ROLE_CONSUMER} ? 1 : 0,
        ($self->{+SCOPE} eq 'run' && ref($self->{+RUN})
            ? (run_id => $self->{+RUN}->run_id)
            : ()),
        (defined $self->{+RELOADER_CLASS}
            ? (reloader_class => $self->{+RELOADER_CLASS},
               reloader_args  => ($self->{+RELOADER_ARGS} // {}))
            : ()),
        exec => {
            cmd           => \@cmd,
            stay_in_begin => 1,
        },
    );
    return (['Test2::Harness2::PreloadService', @args]);
}

1;

__END__

=pod

=head1 NAME

Test2::Harness2::Resource::Preload - Resource that owns one
PreloadService process.

=head1 DESCRIPTION

A preload bundles a name and a list of perl modules. The harness
spawns a service per Resource::Preload instance; the service
require()s the modules at startup and waits for spawn_test
requests. Tests routed through this resource become collector
grandchildren of the harness via the service's double-fork +
Long::Jump path.

The Resource itself never participates in slot accounting:
available() always returns 1 and assign/release are no-ops. The
yes/no decision for the scheduler is "is the service ready", which
is_usable answers. Three states drive that:

=over 4

=item * usable -- service has emitted preload_ready

=item * transient broken -- reload-restart cycle in progress, or a
reload-compile-error window pending a user fix

=item * permanent broken -- initial-load failure or restart-spiral
cap exceeded; never cleared without a fresh harness invocation

=back

See AI_DOCS/2026-05-10-preload-rework-design.md sections 3, 4, and
5 for the surrounding architecture.

=head1 METHODS

=head2 init

Object::HashBase initializer. Validates C<name> and C<modules>,
applies defaults for C<scope> and C<is_role_consumer>, and starts
out not-yet-usable. Allows C<scope='run'> without a bound C<run>
so the harness can rehydrate per-run preload specs over IPC; the
Run is attached later via L</set_run>.

=head2 set_run

Binds a L<Test2::Harness2::Run> object after construction. Only
valid for C<scope='run'>; the harness calls this before the
scheduler consults L</services> or L</status>.

=head2 resource_name

Returns C<"preload:NAME">.

=head2 inline_key_prefixes

Returns the inline-key prefixes accepted by L</parse_options>
(C<from>, C<scope>) for the C<-R> CLI shape.

=head2 parse_options

CLI option parser. Accepts C<name=>, C<from=> (mapped to
C<preferred_preload>), C<scope=>, and recognised kwargs from the
internal C<%OPTION_KEYS> set. Croaks on undef / ref / unknown
positional entries.

=head2 needed

Returns 0. Routing lives in the PreloadRouter's
C<resolve_for_job>; the scheduler injects the resolved
Resource::Preload alongside the rest of the assigned resources
rather than picking one itself.

=head2 available

Returns 1. The yes/no decision is "is the service ready" (see
L</is_usable>); there is no slot accounting.

=head2 assign / release

Pure markers. Both return 1 and set no env vars; assignment is
routing, not slot consumption.

=head2 status

Returns a hashref of the resource's identity and current flags
(C<name>, C<scope>, C<usable>, C<broken>, C<permanent_broken>,
C<is_role_consumer>, C<modules>, and C<run_id> when applicable).

=head2 is_usable

Overrides the role default. Returns false while C<broken> or
C<permanent_broken>, or until the service has signalled
preload_ready (C<_usable> set).

=head2 mark_ready / mark_unusable / mark_broken / mark_permanent_broken / mark_paused / mark_resumed

State transitions driven by the harness in response to C<preload_*>
IPC events. C<mark_ready> is the only way out of transient
C<broken>; C<mark_permanent_broken> is sticky. C<mark_paused> /
C<mark_resumed> are no-ops because preloads do not participate in
pause semantics.

=head2 services

Returns the spawn recipe for the PreloadService. Builds a fresh
C<perl> invocation with C<@INC> propagated as C<-I> flags and
C<stay_in_begin=1> so L<IPC::Manager::Service::State>'s C<import>
runs the service loop synchronously at BEGIN time of the spawned
C<-e> snippet -- the only state in which L<goto::file> can usefully
install a source filter from inside L<Test2::Harness2::PreloadService/run>.

=cut
