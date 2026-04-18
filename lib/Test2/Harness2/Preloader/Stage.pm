package Test2::Harness2::Preloader::Stage;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX ();
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/mod2file/;

use Object::HashBase qw{
    <name
    <ipcm_info
    <parent_pid
    <workdir
    <stage_obj
    <preloader_name
    <jump_label
    +pid
    +watch_pids_ref
    +child_stage_pids
};

use Role::Tiny::With;
with 'IPC::Manager::Role::Service';

# Exposed so DSL watch() calls outside a stage block can find the stage
# that is *currently* servicing a test launch. The preloader service's own
# process does not set this; each stage-service child does.
our $ACTIVE;

# ---------------------------------------------------------------------------
# Construction / spawn
# ---------------------------------------------------------------------------

sub init {
    my $self = shift;

    croak "'name' is required"       unless defined $self->{+NAME};
    croak "'ipcm_info' is required"  unless defined $self->{+IPCM_INFO};
    croak "'stage_obj' is required"  unless defined $self->{+STAGE_OBJ};
    croak "'parent_pid' is required" unless defined $self->{+PARENT_PID};
    croak "'jump_label' is required" unless defined $self->{+JUMP_LABEL};

    $self->{+WATCH_PIDS_REF}    //= [$self->{+PARENT_PID}];
    $self->{+CHILD_STAGE_PIDS}  //= {};
}

# Fork a new stage-service child from the current process. The parent
# returns the child pid; the child enters the service loop and never
# returns.
#
# $parent_context is a hashref carrying ipcm_info, workdir, jump_label,
# parent_pid (the process that is forking), and preloader_name.
sub fork_and_run {
    my $class = shift;
    my (%args) = @_;

    my $stage    = $args{stage_obj}    or croak "'stage_obj' is required";
    my $ipcm     = $args{ipcm_info}    or croak "'ipcm_info' is required";
    my $jump     = $args{jump_label}   or croak "'jump_label' is required";
    my $parent   = $args{parent_pid}   //= $$;
    my $workdir  = $args{workdir}      // '';
    my $preload  = $args{preloader_name} // 'preloader';
    my $name     = $args{name}         // $stage->name;

    my $pid = fork // die "fork: $!";

    if ($pid) {
        # Parent: just hand back the pid. The service loop runs in the child.
        return $pid;
    }

    # Child: never returns.
    my $self = $class->new(
        name           => $name,
        ipcm_info      => $ipcm,
        parent_pid     => $parent,
        workdir        => $workdir,
        stage_obj      => $stage,
        preloader_name => $preload,
        jump_label     => $jump,
    );

    $self->_run_as_service;

    # _run_as_service uses POSIX::_exit; this is a belt-and-suspenders guard.
    POSIX::_exit(0);
}

sub _run_as_service {
    my $self = shift;

    local $ACTIVE = $self;

    $self->_apply_load_sequence;
    $self->_spawn_child_stages;

    # The stage reports "service started" via a simple side-channel file so
    # the base preloader can confirm the child has loaded. IPC::Manager's
    # own readiness mechanism also works; this is complementary.

    my $exit = $self->run;
    POSIX::_exit($exit // 0);
}

sub _apply_load_sequence {
    my $self = shift;

    my $seq = $self->{+STAGE_OBJ}->load_sequence // [];

    for my $item (@$seq) {
        if (ref($item) eq 'CODE') {
            my $ok = eval { $item->(); 1 };
            unless ($ok) {
                die "Preloader stage '" . $self->{+NAME} . "' load step failed: $@";
            }
        }
        else {
            my $ok = eval { require(mod2file($item)); 1 };
            unless ($ok) {
                die "Preloader stage '" . $self->{+NAME} . "' failed to load '$item': $@";
            }
        }
    }

    return;
}

sub _spawn_child_stages {
    my $self = shift;

    my $children = $self->{+STAGE_OBJ}->children // [];
    return unless @$children;

    for my $child (@$children) {
        my $pid = __PACKAGE__->fork_and_run(
            stage_obj       => $child,
            ipcm_info       => $self->{+IPCM_INFO},
            parent_pid      => $$,
            workdir         => $self->{+WORKDIR},
            preloader_name  => $self->{+PRELOADER_NAME},
            jump_label      => $self->{+JUMP_LABEL},
        );

        $self->{+CHILD_STAGE_PIDS}->{$pid} = $child->name;
    }
}

# ---------------------------------------------------------------------------
# IPC::Manager::Role::Service required accessors.
# ---------------------------------------------------------------------------

sub orig_io    { {} }
sub pid        { $_[0]->{+PID} //= $$ }
sub set_pid    { $_[0]->{+PID} = $_[1] }
sub watch_pids { $_[0]->{+WATCH_PIDS_REF} }

sub handle_request {
    my ($self, $req, $msg) = @_;

    my $payload = $req->{request};
    $payload = {request => $payload} unless ref($payload) eq 'HASH';

    my $type = $payload->{request};
    return {ok => 0, error => "missing request type"} unless defined $type;

    my $handler = "request_handler_$type";
    return $self->$handler($payload) if $self->can($handler);

    return {ok => 0, error => "unknown request '$type'"};
}

# ---------------------------------------------------------------------------
# Request handlers
# ---------------------------------------------------------------------------

sub request_handler_ping {
    my $self = shift;
    return {ok => 1, pong => $$, stage => $self->{+NAME}};
}

sub request_handler_status {
    my $self = shift;
    my $stage = $self->{+STAGE_OBJ};
    return {
        ok        => 1,
        stage     => $self->{+NAME},
        pid       => $$,
        children  => {%{$self->{+CHILD_STAGE_PIDS}}},
        loaded    => [@{$stage->load_sequence // []}],
        watches   => [sort keys %{$stage->watches // {}}],
    };
}

sub request_handler_shutdown {
    my $self = shift;
    $self->terminate(0);
    return {ok => 1};
}

# launch_test payload (at minimum):
#   test_file => '/abs/path/to/t/foo.t'      (required)
#   env       => { ... }                     (optional environment overrides)
#   argv      => [ ... ]                     (optional @ARGV for the test)
#   loggers   => [ ... ]                     (optional; default: none)
#   auditor   => 'Class' | $instance         (optional)
#   parser    => 'Class'                     (optional)
#   run_id / job_id / job_try                (optional identifiers)
#
# The stage forks. The parent returns immediately with the
# collector-process pid so the harness can track it. The forked child is
# handed off to Test2::Harness2::Collector::Preloaded::launch, which forks
# again (collector -> test), runs pre_fork/post_fork/pre_launch, and
# longjumps the test payload all the way up to the base preloader's
# setjump point; the landing there hands control to the test file via
# goto::file.
sub request_handler_launch_test {
    my $self = shift;
    my ($payload) = @_;

    my $test_file = $payload->{test_file};
    return {ok => 0, error => "launch_test requires a 'test_file'"}
        unless defined $test_file && length $test_file;

    my $stage = $self->{+STAGE_OBJ};

    # pre_fork runs in the stage parent (before any fork). State mutations
    # here will bleed into this stage's future forks, which is documented
    # (and desired) behavior.
    my $pf_ok = eval { $stage->do_pre_fork($payload); 1 };
    my $pf_err = $@;
    unless ($pf_ok) {
        return {ok => 0, error => "pre_fork hook failed: $pf_err"};
    }

    my $pid = fork // die "fork: $!";

    if ($pid) {
        return {
            ok             => 1,
            stage          => $self->{+NAME},
            collector_pid  => $pid,
        };
    }

    # ----- forked child from here on -----
    # Hand off to the preloaded collector helper. It forks again internally
    # (collector stays here, test process becomes the grandchild of the
    # stage), wires the collector pipes, runs post_fork / pre_launch, and
    # longjumps the test payload back to the base preloader.
    require Test2::Harness2::Collector::Preloaded;

    Test2::Harness2::Collector::Preloaded->launch(
        stage_obj  => $stage,
        test_file  => $test_file,
        jump_label => $self->{+JUMP_LABEL},
        ipcm_info  => $self->{+IPCM_INFO},
        loggers    => $payload->{loggers} // [],
        (defined $payload->{auditor} ? (auditor => $payload->{auditor}) : ()),
        (defined $payload->{parser}  ? (parser  => $payload->{parser})  : ()),
        (defined $payload->{run_id}  ? (run_id  => $payload->{run_id})  : ()),
        (defined $payload->{job_id}  ? (job_id  => $payload->{job_id})  : ()),
        (defined $payload->{job_try} ? (job_try => $payload->{job_try}) : ()),
        (defined $payload->{env}     ? (env     => $payload->{env})     : ()),
        (defined $payload->{argv}    ? (argv    => $payload->{argv})    : ()),
    );

    # Unreachable; launch() either interposes into a collector loop (which
    # exits via POSIX::_exit) or longjumps into the preloader.
    POSIX::_exit(254);
}

# ---------------------------------------------------------------------------
# Service lifecycle hooks
# ---------------------------------------------------------------------------

sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    # A nested child stage exited. Restart it by consulting the stage tree.
    my $child_name = delete $self->{+CHILD_STAGE_PIDS}->{$pid};
    return unless defined $child_name;

    warn "$$ $0 - Stage '" . $self->{+NAME} . "': child stage '$child_name' (pid $pid) exited (status=$exit); restarting\n";

    my $child_stage = _find_child_by_name($self->{+STAGE_OBJ}, $child_name);
    return unless $child_stage;

    my $new_pid = __PACKAGE__->fork_and_run(
        stage_obj       => $child_stage,
        ipcm_info       => $self->{+IPCM_INFO},
        parent_pid      => $$,
        workdir         => $self->{+WORKDIR},
        preloader_name  => $self->{+PRELOADER_NAME},
        jump_label      => $self->{+JUMP_LABEL},
    );

    $self->{+CHILD_STAGE_PIDS}->{$new_pid} = $child_name;

    return;
}

sub _find_child_by_name {
    my ($stage, $name) = @_;
    for my $child (@{$stage->children // []}) {
        return $child if $child->name eq $name;
    }
    return;
}

sub run_on_cleanup {
    my $self = shift;

    # Terminate any child stages we spawned.
    for my $pid (keys %{$self->{+CHILD_STAGE_PIDS} // {}}) {
        kill TERM => $pid;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preloader::Stage - Per-stage service in the preloader
service tree.

=head1 DESCRIPTION

Each stage declared in a preload library becomes one of these services.
Stages are arranged as a tree mirroring the DSL nesting: top-level stages
are children of the base L<Test2::Harness2::Preloader> service, nested
stages are children of their enclosing stage.

Lifecycle:

=over 4

=item 1. The parent (preloader or a parent stage) calls L</fork_and_run>.

=item 2. The child runs the stage's C<load_sequence> (requires / code
callbacks), then spawns any nested child stages.

=item 3. The child registers with L<IPC::Manager> under the stage name and
enters the service loop.

=item 4. When a C<launch_test> request arrives, the stage forks a child
test process. The forked child runs C<post_fork> and C<pre_launch>
callbacks, then C<longjump>s back to the base preloader's setjump
landing, where L<goto::file> takes over and runs the test with a
near-empty Perl stack.

=item 5. If a nested child stage dies, L</run_on_pid> automatically
restarts it.

=back

=head1 REQUEST HANDLERS

=over 4

=item ping

C<{ok =E<gt> 1, pong =E<gt> $pid, stage =E<gt> $name}>.

=item status

Snapshot of the stage: name, pid, child-stage pids, load sequence, and
watch list.

=item launch_test

Fork a test process and hand it to the test file via longjump. Accepts:

    test_file => $path   (required)
    env       => \%env   (optional environment overrides)
    argv      => \@argv  (optional @ARGV for the test)

Returns C<{ok =E<gt> 1, stage =E<gt> $name, test_pid =E<gt> $pid}> in the
stage parent; the child never returns (it longjumps to the preloader
root).

=item shutdown

Terminate this stage's service loop. Child stages are killed during
cleanup.

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
