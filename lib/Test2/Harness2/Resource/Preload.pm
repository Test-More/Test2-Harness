package Test2::Harness2::Resource::Preload;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempfile/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <preload
    <stage
    <workdir
    +service_name
    +config_file
    +pid
    +default_stage
    <broken
    <paused
    <permanent_broken
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub resource_name  { 'preload' }
sub is_job_limiter { 0 }

sub init {
    my $self = shift;

    $self->{+PRELOAD} //= [];
    croak "'preload' must be an arrayref"
        unless ref($self->{+PRELOAD}) eq 'ARRAY';

    croak "'workdir' is a required attribute"
        unless defined $self->{+WORKDIR};

    croak "'workdir' must point at an existing directory"
        unless -d $self->{+WORKDIR};

    # Service name defaults to 'preload' but can be overridden to
    # disambiguate a per-run preload from a harness-global preload;
    # IPC_AND_LOGGERS §10.2 gives run-scoped stages a ":<run_id>"
    # suffix in their bus identity. For Stage 8 this stays one-shot:
    # a single harness-global preload service.
    $self->{+SERVICE_NAME} //= 'preload';
}

# Allow the runner to restrict this resource to jobs that actually
# want a preload stage. A TestFile may declare a STAGE-NAME directive
# or the caller may pass use_preload_for to control this; for Stage 8
# we just accept every job and rely on Command::test to only attach
# the resource when --preload is set.
sub needed { 1 }

sub available {
    # The preload resource does not gate slots; it is an "assistance"
    # resource that provides a preloaded interpreter for scheduling.
    # Return 1 unconditionally so the scheduler never defers a job
    # on its account. Broken/permanent-broken checks are still
    # handled upstream in the scheduler via is_usable.
    return 1;
}

sub assign {
    my ($self, %p) = @_;
    # No bookkeeping to do on assignment: the preload service fork
    # happens elsewhere (inside RunService's launch_job path, when
    # the preload resource is reachable on the bus). We stamp the
    # stage name into the env so downstream consumers that care can
    # see it.
    my $env = $p{env} or croak "'env' hashref is required";
    $env->{T2_HARNESS_PRELOAD_STAGE} = $self->_assigned_stage_for($p{job})
        if $self->_assigned_stage_for($p{job});
    return 1;
}

sub release {
    # Nothing to release; see assign().
    return 1;
}

sub status {
    my $self = shift;

    return {
        resource     => $self->resource_name,
        service_name => $self->{+SERVICE_NAME},
        pid          => $self->{+PID},
        preload      => [@{$self->{+PRELOAD}}],
        broken       => $self->is_broken,
        paused       => $self->is_paused,
        permanent    => $self->is_permanent_broken,
    };
}

sub is_broken           { $_[0]->{+BROKEN}           ? 1 : 0 }
sub is_paused           { $_[0]->{+PAUSED}           ? 1 : 0 }
sub is_permanent_broken { $_[0]->{+PERMANENT_BROKEN} ? 1 : 0 }

sub mark_broken           { $_[0]->{+BROKEN}           = 1 }
sub mark_paused           { $_[0]->{+PAUSED}           = 1 }
sub mark_resumed          { $_[0]->{+BROKEN}           = 0; $_[0]->{+PAUSED} = 0 }
sub mark_permanent_broken { $_[0]->{+PERMANENT_BROKEN} = 1; $_[0]->{+BROKEN} = 1 }

# The scheduler consults this before calling service_preload_start.
# Return 0 to skip the service entirely (e.g. the harness was
# constructed with a Preload resource but no actual preload modules,
# so there is nothing to keep warm). Stage 8 accepts any configured
# preload; future CLI surfaces may tighten this.
sub service_preload_applicable {
    my $self = shift;
    return scalar @{$self->{+PRELOAD}} ? 1 : 0;
}

# Stage 8 ships a non-restartable preload service: a crash flips the
# resource permanent-broken and the scheduler's broken_resource_behavior
# (skip/fail/abort) covers the pending tests. Stage 9 will add reloading
# and bring restartability with it.
sub service_preload_restartable { 0 }

# The service method the harness's ResourceServiceHost invokes at
# startup. Fork+exec a fresh perl with our Bootstrap inline; the
# Bootstrap loads the configured preloads inside BEGIN, then hands
# control to IPC::Manager's service-state path for the service loop.
sub service_preload_start {
    my ($self, %args) = @_;

    my $harness  = $args{harness} or croak "'harness' is required";
    my $scope    = $args{scope} // 'global';
    my $name     = $args{name}  // $self->{+SERVICE_NAME};
    my $log_path = $args{log_path};

    my $ipcm_info = $harness->ipcm_info
        or croak "harness has no ipcm_info; cannot start preload service";

    my $config_file = $self->_write_config_file(
        name         => $name,
        scope        => $scope,
        ipcm_info    => $ipcm_info,
        workdir      => $self->{+WORKDIR},
        log_path     => $log_path,
        harness_name => $harness->name,
        harness_pid  => $$,
    );
    $self->{+CONFIG_FILE} = $config_file;

    require IPC::Manager;

    # ipcm_service with exec => { stay_in_begin => 1 } enters the
    # service loop from inside the exec'd child's BEGIN. Our
    # Bootstrap module, loaded earlier in the exec argv, runs the
    # preload recipe before IPC::Manager::Service::State takes over
    # -- so every configured module ends up in %INC in the root
    # preload process before the first launch_job arrives.
    my $handle = IPC::Manager::ipcm_service(
        $name,
        class        => 'Test2::Harness2::PreloadService',
        workdir      => $self->{+WORKDIR},
        name         => $name,
        ipcm_info    => $ipcm_info,
        parent_pids  => [$$],
        config_file  => $config_file,
        harness_name => $harness->name,
        log_path     => $log_path,
        exec         => {
            cmd => [
                (map { "-I$_" } grep { defined $_ && length $_ } @INC),
                "-MTest2::Harness2::PreloadService::Bootstrap=$config_file",
            ],
            stay_in_begin => 1,
        },
    );

    my $pid = $handle->pid;
    $self->{+PID} = $pid;

    $harness->track_resource_service(
        pid      => $pid,
        resource => $self,
        method   => 'service_preload_start',
        scope    => $scope,
        name     => $name,
        log_path => $log_path,
        (defined $args{run} ? (run => $args{run}) : ()),
    );

    return;
}

sub _assigned_stage_for {
    my ($self, $job) = @_;
    return undef unless defined $job;
    my $tf = $job->test_file or return undef;

    # Stage 8: test files do not yet carry an explicit stage
    # directive (that arrives when Command::test adds directive
    # scanning). Always use the default stage, if we have one.
    return $self->{+DEFAULT_STAGE} // $self->{+STAGE};
}

sub _write_config_file {
    my ($self, %p) = @_;

    my $dir = File::Spec->catdir($self->{+WORKDIR}, 'preload');
    make_path($dir) unless -d $dir;

    my ($fh, $path) = tempfile(
        "preload-config-XXXXXXXX",
        SUFFIX => '.json',
        DIR    => $dir,
    );

    # Stage-tree data is intentionally serialised lightly here: the
    # preload root service resolves DSL metadata by loading the
    # listed modules under BEGIN in its own fresh process. Only the
    # module-name list needs to survive the exec.
    my %config = (
        name            => $p{name},
        scope           => $p{scope},
        ipcm_info       => $p{ipcm_info},
        workdir         => $p{workdir},
        log_path        => $p{log_path},
        harness_name    => $p{harness_name},
        harness_pid     => $p{harness_pid},
        preload_modules => [@{$self->{+PRELOAD}}],
    );

    print $fh encode_json(\%config);
    close $fh or die "close '$path': $!";

    return $path;
}

sub teardown {
    my $self = shift;

    # Best-effort config file cleanup. The preload service process
    # is reaped by the harness's ResourceServiceHost path; this
    # hook only needs to remove the bits the resource itself owns.
    if (my $cfg = $self->{+CONFIG_FILE}) {
        unlink $cfg if -f $cfg;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::Preload - Preload resource exposing a
preloaded service tree to the harness scheduler.

=head1 DESCRIPTION

Wraps the preload service (L<Test2::Harness2::PreloadService>) in a
L<Test2::Harness2::Role::Resource> so the harness can start it
through the same C<service_*_start> plumbing every other
service-backed resource uses. The resource itself has no slot-gating
behaviour; its job is to own the preload service's lifecycle.

Per C<IPC_AND_LOGGERS> section 10, a preload is "just another
resource that happens to bring a service subtree with it". This
class is the plain Role::Resource end of that subtree.

=head1 ATTRIBUTES

=over 4

=item preload

Arrayref of module names (strings) to load inside the preload root
service's BEGIN before the service loop starts. DSL preload
libraries (modules that consume L<Test2::Harness2::Preload>) are
loaded the same way; the preload service detects them by the
presence of a C<TEST2_HARNESS_PRELOAD> marker and merges their
stage metadata.

=item workdir

Directory the preload service can write ephemeral config files
under (C<$workdir/preload/>).

=item stage / default_stage

Optional overrides naming the stage a test without an explicit
stage directive should run under. Scanning test files for
C<HARNESS-STAGE-NAME> directives is deferred; this attribute is
the Stage 8 fallback.

=back

=head1 RESOURCE HOOKS

The implementation is intentionally minimal for Stage 8:

=over 4

=item * C<available> always returns C<1>; the preload resource does
not gate slots.

=item * C<assign> stamps C<T2_HARNESS_PRELOAD_STAGE> into the child
environment if a stage is known, so downstream consumers can key off
it.

=item * C<release> is a no-op.

=item * C<service_preload_applicable> returns true only when the
preload list is non-empty -- a resource with no modules to preload
is effectively a no-op.

=item * C<service_preload_restartable> returns 0 for Stage 8. The
preload service is non-restartable; a crash flips the resource
C<permanent_broken> and the scheduler's
C<broken_resource_behavior> covers the pending tests. Stage 9 will
add reloading and bring restartability.

=item * C<service_preload_start> fork+execs a fresh perl with
L<Test2::Harness2::PreloadService::Bootstrap> loaded in the exec
argv. IPC::Manager's C<exec + stay_in_begin> path enters the
service loop from inside BEGIN; Bootstrap runs the preload recipe
before IPC::Manager takes over so every configured module ends up
in C<%INC> before the first C<launch_job>.

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
