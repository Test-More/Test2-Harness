package Test2::Harness2::ResourceService::PreloadRoot;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX ();

use Test2::Harness2::Util qw/mod2file/;

use Object::HashBase qw{
    <preloads
    <preload_early
    <harness_name
    <logdir
    <name
    ipcm_info
    watch_pids
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::ResourceService';

sub restartable { 1 }

sub handle_request {
    my ($self, $req, $msg) = @_;

    my $payload = ref($req) eq 'HASH' ? $req : {};
    my $inner   = $payload->{request};
    $inner = {request => $inner} unless ref($inner) eq 'HASH';

    my $type    = $inner->{request};
    my $handler = "request_handler_$type";

    return {ok => 0, error => "missing request type"} unless defined $type;
    return $self->$handler($inner) if $self->can($handler);
    return {ok => 0, error => "unknown request '$type'"};
}

sub run_on_start {
    my $self = shift;

    $ENV{T2_TRACE_STAMPS} = 1;

    if (eval { require Test2::API; 1 }) {
        Test2::API::test2_start_preload();
        Test2::API::test2_enable_trace_stamps();
    }

    for my $mod (@{$self->{+PRELOADS}}) {
        my $ok  = eval { require(mod2file($mod)); 1 };
        my $err = $@;
        warn "PreloadRoot: failed to load '$mod': $err" unless $ok;
    }

    $self->_send_to_harness({kind => 'stage_up', stage => $self->{+NAME}, pid => $$});
}

sub run_on_cleanup {
    my $self = shift;
    $self->_send_to_harness({kind => 'stage_down', stage => $self->{+NAME}});
}

sub request_handler_launch_job {
    my ($self, $payload) = @_;

    for my $req (qw/job_id run_id test_file/) {
        return {ok => 0, error => "'$req' is required"} unless defined $payload->{$req};
    }

    my $job_id   = $payload->{job_id};
    my $job_try  = $payload->{job_try} // 0;
    my $run_id   = $payload->{run_id};
    my $env      = $payload->{env} // {};
    my $auditor  = $payload->{auditor};
    my $test_abs = $payload->{test_file};

    return {ok => 0, error => "'test_file' must be absolute"}
        unless $test_abs =~ m{^/};

    pipe(my $r, my $w) // die "pipe: $!";

    my $ipid = fork // die "Failed to fork intermediary: $!";

    if ($ipid) {
        close $w;
        my $cpid_str = do { local $/; <$r> };
        close $r;
        waitpid($ipid, 0);

        return {ok => 0, error => "failed to obtain collector pid from intermediary"}
            unless defined $cpid_str && $cpid_str =~ m/^\d+$/;

        return {ok => 1, pid => 0 + $cpid_str};
    }

    # Intermediary child
    close $r;

    my $handle;
    my $spawn_ok = eval {
        require Test2::Harness2::Collector::Preloaded;
        $handle = Test2::Harness2::Collector::Preloaded->spawn(
            new_pgroup  => 1,
            parent_pids => [$$],
            env_vars    => {T2_FORMATTER => 'Stream2', %$env},
            logdir      => $self->{+LOGDIR},
            run_id      => $run_id,
            job_id      => $job_id,
            job_try     => $job_try,
            ipcm_info   => $self->ipcm_info,
            ipc_parent  => "run-$run_id",
            ipc_run     => "run-$run_id",
            ipc_harness => $self->{+HARNESS_NAME} // 'harness',
            test_file   => $test_abs,
            (defined $auditor ? (auditor => $auditor) : ()),
        );
        1;
    };
    my $spawn_err = $@;

    if ($spawn_ok && $handle) {
        print $w $handle->pid;
    }
    else {
        warn "PreloadRoot: collector spawn failed: $spawn_err";
    }

    close $w;
    POSIX::_exit($spawn_ok ? 0 : 1);
}

sub _send_to_harness {
    my ($self, $msg) = @_;

    my $ok = eval {
        require IPC::Manager::Service::Handle;
        my $hname  = $self->{+HARNESS_NAME} // 'harness';
        my $handle = IPC::Manager::Service::Handle->new(
            service_name => $hname,
            ipcm_info    => $self->ipcm_info,
        );
        $handle->client->send_message($hname, $msg);
        1;
    };
    warn "PreloadRoot: could not notify harness: $@" unless $ok;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::ResourceService::PreloadRoot - IPC::Manager service that
loads preload modules and launches tests from a forked state.

=head1 DESCRIPTION

This is the resource service that backs L<Test2::Harness2::Resource::Preload>.
It runs as a long-lived supervised subprocess managed by the harness.

On startup (C<run_on_start>) it enables the C<Test2::API> preload mode,
loads every module listed in C<preloads>, and sends a C<stage_up> message
to the harness so the preload resource can begin routing jobs here.

When the harness sends a C<launch_job> request, C<request_handler_launch_job>
performs the double-fork detachment pattern:

=over 4

=item 1.

Fork a short-lived B<intermediary> child.

=item 2.

The intermediary forks the B<collector> (a
L<Test2::Harness2::Collector::Preloaded>) and exits immediately, detaching
the collector from this service's process tree.

=item 3.

The stage reads the collector pid from a pipe and returns it as the
C<launch_job> response.

=back

On shutdown (C<run_on_cleanup>) it sends a C<stage_down> message to the
harness.

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
