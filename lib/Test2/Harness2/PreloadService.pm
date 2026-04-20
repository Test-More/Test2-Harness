package Test2::Harness2::PreloadService;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use POSIX ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <workdir
    <name
    <config_file
    <harness_name
    <log_path
    <parent_pids
    <kill_timeout
    +state
    +launches
    +log_fh
    +watch_pids_ref
    +own_pgroup
    +meta
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

# The preload root service acts as a subreaper so orphaned test
# children (e.g. if a collector dies mid-run) reparent to us and can
# be cleaned up inside perform_hard_stop.
sub become_sub_reaper { 1 }

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;

    $self->{+NAME}           //= 'preload';
    $self->{+HARNESS_NAME}   //= 'harness';
    $self->{+KILL_TIMEOUT}   //= 15;
    $self->{+PARENT_PIDS}    //= [];
    $self->{+STATE}          //= 'running';
    $self->{+LAUNCHES}       //= {};
    $self->{+WATCH_PIDS_REF} //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}     //= 0;
}

# ipcm_info is stored as the bare 'ipcm_info' key (not a HashBase slot)
# because IPC::Manager::Service::State's params dump uses that name.
sub ipcm_info { $_[0]->{ipcm_info} }

# --- Merge DSL meta-objects from already-loaded preload modules. -----
#
# Bootstrap requires each preload module, which installs a
# TEST2_HARNESS_PRELOAD sub on any module that consumes the DSL. We
# walk the Bootstrap config's module list and merge every marked
# module's meta into our own, so the service has a unified stage
# tree. Called from service_on_start so every module is settled
# before we look.
sub _build_meta {
    my $self = shift;

    my $cfg_file = $self->{+CONFIG_FILE} or return;
    return unless -f $cfg_file;

    require Test2::Harness2::Util::JSON;
    my $json = do {
        open my $fh, '<', $cfg_file or die "open '$cfg_file': $!";
        local $/;
        <$fh>;
    };
    my $config = Test2::Harness2::Util::JSON::decode_json($json);

    my $preloads = $config->{preload_modules} // [];

    require Test2::Harness2::Preload;

    my $meta = Test2::Harness2::Preload->new;
    for my $mod (@$preloads) {
        my $marker   = $mod->can('TEST2_HARNESS_PRELOAD') or next;
        my $mod_meta = $marker->();
        next unless $mod_meta;
        $meta->merge($mod_meta);
    }

    $self->{+META} = $meta;

    return;
}

# --- Role::Service required methods -----------------------------------

sub emit_service_event {
    my ($self, %fields) = @_;

    my $fh = $self->{+LOG_FH};
    unless ($fh) {
        my $path = $self->{+LOG_PATH} or return;
        open($fh, '>>', $path)        or warn("open '$path': $!") and return;
        $fh->autoflush(1);
        $self->{+LOG_FH} = $fh;
    }

    my $event_id = gen_uuid();
    my $stamp    = time;
    my $event    = {
        event_id   => $event_id,
        stamp      => $stamp,
        pid        => $$,
        facet_data => {
            harness => {
                event_id => $event_id,
                stamp    => $stamp,
                name     => $self->{+NAME},
                %fields,
            },
        },
    };

    my $ok = eval { print $fh encode_json($event), "\n"; 1 };
    warn "preload-service event emit failed: $@" unless $ok;
    return;
}

sub hard_stop_pids {
    my $self = shift;

    my %pids;
    for my $info (values %{$self->{+LAUNCHES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }
    return %pids;
}

# Role::Service hooks: keep the service_started event informative and
# pull in DSL meta after startup so the service has a coherent stage
# table from its first launch_job request.
sub service_started_fields {
    my $self = shift;
    return (role => 'preload');
}

sub service_on_start {
    my $self = shift;

    my $ok  = eval { $self->_build_meta; 1 };
    my $err = $@;
    warn "preload meta build failed: $err" unless $ok;

    return;
}

sub service_on_reaped {
    my ($self, $pid) = @_;
    delete $self->{+LAUNCHES}->{$pid};
    return;
}

sub service_post_hard_stop {
    my $self = shift;
    $self->{+LAUNCHES} = {};
    return;
}

sub run_should_end {
    my $self = shift;

    return 0 unless $self->{+STATE} eq 'terminating';

    # Wait until every test collector we were tracking has exited
    # before unwinding the loop, so their own IPC disconnect + event
    # flush happens before the preload service tears down the bus.
    return 0 if keys %{$self->{+LAUNCHES} // {}};
    return 1;
}

# --- Request handlers -------------------------------------------------

sub request_handler_ping {
    my $self = shift;
    return {ok => 1, pong => $$, name => $self->{+NAME}};
}

sub request_handler_status {
    my $self = shift;

    my @jobs;
    for my $info (values %{$self->{+LAUNCHES} // {}}) {
        push @jobs => {
            pid        => $info->{pid},
            run_id     => $info->{run_id},
            job_id     => $info->{job_id},
            job_try    => $info->{job_try},
            started_at => $info->{started_at},
            stage      => $info->{stage},
        };
    }

    return {
        service => {
            name    => $self->{+NAME},
            pid     => $$,
            workdir => $self->{+WORKDIR},
            state   => $self->{+STATE},
            stages  => [$self->{+META} ? sort keys %{$self->{+META}->stage_lookup // {}} : ()],
        },
        launches => \@jobs,
    };
}

# launch_job: fork a test-job collector + test process and return
# the collector pid.
#
# The payload mirrors RunService's launch_job: run_id, job_id, job_try,
# test_file, env, auditor, loggers. No launch argv because the test
# runs in-process via `do $test_file` after the interpose fork
# completes -- reusing this process's preloaded %INC is the whole
# point of the preload system.
#
# Stage 8 compromise: per IPC_AND_LOGGERS section 10.4 the test-job
# collector should be detached from the preload stage via an
# intermediary fork+exit so the stage can be pruned or reloaded
# without killing running tests. Stage 9 (preload reloading)
# introduces reload, and with it the detach pattern becomes
# load-bearing. Until then the collector is a direct child of the
# preload service and the service reaps it in service_on_reaped;
# stage reload is not a feature yet, so the shortcut is safe.
sub request_handler_launch_job {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'preload service not accepting launches'}
        if $self->{+STATE} ne 'running';

    for my $required (qw/run_id job_id test_file/) {
        return {ok => 0, error => "'$required' is required"}
            unless defined $payload->{$required};
    }

    my $run_id    = $payload->{run_id};
    my $job_id    = $payload->{job_id};
    my $job_try   = $payload->{job_try} // 0;
    my $test_file = $payload->{test_file};
    my $env       = $payload->{env} // {};
    my $auditor   = $payload->{auditor};
    my $loggers   = $payload->{loggers} // [];
    my $stage     = $payload->{stage};

    return {ok => 0, error => "'test_file' must be absolute"}
        unless $test_file =~ m{^/};

    return {ok => 0, error => "test file '$test_file' does not exist"}
        unless -f $test_file;

    # Fork: the parent stays in the preload service loop, the child
    # becomes the stage-launch process that calls Collector->interpose.
    my $pid = fork // die "preload launch fork failed: $!";

    if ($pid) {
        $self->{+LAUNCHES}->{$pid} = {
            pid        => $pid,
            run_id     => $run_id,
            job_id     => $job_id,
            job_try    => $job_try,
            stage      => $stage,
            started_at => time,
        };
        return {ok => 1, pid => $pid, stage => $stage};
    }

    # ----- forked stage-launch child from here on -----
    #
    # We do NOT return to the service loop: interpose forks into
    # (collector, test); the collector runs its read loop and exits;
    # the test continues with `do $test_file`.
    $self->_run_launch_child(
        run_id    => $run_id,
        job_id    => $job_id,
        job_try   => $job_try,
        test_file => $test_file,
        env       => $env,
        auditor   => $auditor,
        loggers   => $loggers,
        stage     => $stage,
    );

    # _run_launch_child always _exits; this is a belt-and-suspenders.
    POSIX::_exit(255);
}

sub _run_launch_child {
    my ($self, %p) = @_;

    my $run_id    = $p{run_id};
    my $job_id    = $p{job_id};
    my $job_try   = $p{job_try};
    my $test_file = $p{test_file};
    my $env       = $p{env} // {};
    my $auditor   = $p{auditor};
    my $loggers   = $p{loggers} // [];

    # interpose's parent becomes the collector and exits from that
    # code path; its child (us) returns here with STDOUT/STDERR swapped
    # to the collector's pipes.
    Test2::Harness2::Collector->interpose(
        ipcm_info   => $self->ipcm_info,
        ipc_parent  => $self->{+NAME},
        ipc_run     => $run_id,
        ipc_harness => $self->{+HARNESS_NAME},
        kind        => 'test',
        loggers     => $loggers,
        parser      => 'Test2::Harness2::Collector::Parser::IOParser::Stream',
        parent_pids => [$self->pid],
        run_id      => $run_id,
        job_id      => $job_id,
        job_try     => $job_try,
        (defined $auditor ? (auditor => $auditor) : ()),
    );

    # ----- the test child from here on -----

    # Apply environment overrides the scheduler passed in.
    for my $k (keys %$env) {
        $ENV{$k} = $env->{$k};
    }
    $ENV{T2_FORMATTER} //= 'Stream2';

    # Rebase $0 so tools that key off of it see the test file.
    $0 = $test_file;

    # Rewind @ARGV to whatever the caller passed (or empty).
    @ARGV = @{$p{argv} // []};

    # `do` runs the test file in the current process, reusing the
    # preloaded %INC. STDOUT/STDERR are already piped to the
    # collector so Test2::Formatter::Stream2 events flow through.
    my $ok = do {
        local $@;
        my $v = eval { do $test_file; 1 };
        my $e = $@;
        $v ? $v : (warn $e, 0);
    };

    # Flush STDOUT/STDERR before exit so Atomic::Pipe writes land
    # in the collector's read loop before the pipe closes.
    STDOUT->flush if fileno(STDOUT);
    STDERR->flush if fileno(STDERR);

    POSIX::_exit($ok ? 0 : 1);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::PreloadService - Preload root service. Hosts a
pre-warmed interpreter; forks test-job collectors on demand.

=head1 DESCRIPTION

Implements the preload root service described in
C<IPC_AND_LOGGERS> section 10. A L<Test2::Harness2::Resource::Preload>
fork+execs this class via L<IPC::Manager>'s C<exec + stay_in_begin>
path; L<Test2::Harness2::PreloadService::Bootstrap> loads the
configured preload modules during that exec'd process's BEGIN, and
the service loop then accepts C<launch_job> requests from the
harness.

=head1 STAGE 8 SCOPE

Stage 8 ships the initial preload system without reloading or
stage-subtree supervision. Simplifications relative to
C<IPC_AND_LOGGERS> section 10:

=over 4

=item * No stage-subtree services: the root preload service serves
every launch directly. Stage subtree services (nested stages as
their own processes) arrive in a follow-up stage as the preload
resource gains actual stage-switching.

=item * No detach pattern: the test-job collector is a direct child
of the preload service, not reparented via an intermediary fork+exit.
C<IPC_AND_LOGGERS> section 10.4 requires detachment so the stage can
be pruned/reloaded without killing running tests; Stage 9 will
introduce reload and at that point the detach pattern becomes
load-bearing.

=item * No L<goto::file> test-body substitution: the test file is
executed via C<do $test_file> in the forked test child. The
preloaded C<%INC> is still inherited through fork, which is the
essential preload win; the C<Long::Jump + goto::file> pattern from
C<old/> is a refinement that keeps the test's Perl stack at zero
depth.

=back

These simplifications are documented in the STAGE_SUMMARY for Stage 8.

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
