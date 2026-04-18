package Test2::Harness2::Preloader;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX qw/_exit/;
use Time::HiRes qw/time sleep/;
use Test2::Util::UUID qw/gen_uuid/;

use Long::Jump qw/setjump longjump/;
use goto::file ();

use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Object::HashBase qw{
    <workdir
    <name
    <ipcm_info
    <parent_pids
    +pid
    +watch_pids_ref
    +meta
    +preload_modules
    +started_stage_pids
    +stages
    +jump_label
};

use Role::Tiny::With;
with 'IPC::Manager::Role::Service';

# ---------------------------------------------------------------------------
# Class-level bootstrap machinery. The entry point is bootstrap_main(), which
# is intended to be the *only* thing a freshly-exec'd preloader process runs
# at the top level. A BEGIN block inside the exec'd one-liner prepares the
# module environment; the top-level setjump establishes a stack-zero landing
# for test-launch longjumps.
#
# Runtime contract:
#
#   1. Parent (the harness) writes a JSON config to a temp file.
#   2. Parent fork+exec's `perl -MTest2::Harness2::Preloader -e ...` (see
#      build_exec_argv). The -e snippet calls:
#           BEGIN { Test2::Harness2::Preloader->_begin_bootstrap($cfg) }
#           my $payload = Long::Jump::setjump($label);
#           if ($payload) { ... goto::file ... }
#           else          { Test2::Harness2::Preloader->_serve($cfg) }
#   3. _begin_bootstrap loads the preload config, loads plain modules into
#      the current process, and `use`s any DSL modules so the DSL meta
#      object is populated (stages are recorded but not yet spawned).
#   4. Top-level setjump sets the landing.
#   5. _serve constructs the object and enters the IPC service loop.
#   6. When a test launch is requested the grandchild test process calls
#      longjump back to the top-level setjump frame, where goto::file
#      hands control to the test file with a stack of effectively zero.
# ---------------------------------------------------------------------------

our $JUMP_LABEL;    # exposed so child stages can reach it
our $CONFIG;        # current config, populated by _begin_bootstrap

sub bootstrap_script {
    # The exact source we want `perl -e` to run. Kept in one place so both
    # the documentation and build_exec_argv can agree. The script reads the
    # config-file path from $ARGV[0].
    #
    # Everything substantive happens inside BEGIN. That matters: when a
    # descendant test process longjumps back to the setjump frame, Perl is
    # still in the compile phase of the bootstrap's main file. The
    # post-jump handler can then call goto::file, which is a source filter
    # that only affects what Perl parses next. Running the filter install
    # at runtime of the bootstrap script would be too late -- Perl would
    # already be past the point where the filter would be consulted.
    return <<'SCRIPT';
use strict;
use warnings;
use Test2::Harness2::Preloader;
BEGIN {
    Test2::Harness2::Preloader->_begin_bootstrap($ARGV[0]);
    my $payload = Long::Jump::setjump(
        $Test2::Harness2::Preloader::JUMP_LABEL,
        sub { Test2::Harness2::Preloader->_serve($ARGV[0]) },
    );
    if ($payload) {
        Test2::Harness2::Preloader->_post_jump_launch($payload);
    }
}
SCRIPT
}

sub build_exec_argv {
    my $class = shift;
    my (%p) = @_;

    my $config_file = $p{config_file}
        or croak "'config_file' is required";

    my $script = $class->bootstrap_script;

    return (
        $^X,
        (map { "-I$_" } grep { defined $_ && length $_ } @INC),
        '-e', $script,
        '--', $config_file,
    );
}

# Write config to a temp file. Caller supplies the path (usually workdir).
sub write_config_file {
    my $class = shift;
    my ($dir, $config) = @_;

    croak "directory '$dir' does not exist" unless -d $dir;

    my $file = "$dir/preloader-config-" . gen_uuid() . ".json";
    open my $fh, '>', $file or die "open $file: $!";
    print $fh encode_json($config);
    close $fh;

    return $file;
}

sub _begin_bootstrap {
    my ($class, $config_file) = @_;

    croak "No config file passed to preloader bootstrap"
        unless defined $config_file && length $config_file && -f $config_file;

    open my $fh, '<', $config_file or die "open $config_file: $!";
    local $/;
    my $json = <$fh>;
    close $fh;

    $CONFIG = decode_json($json);

    $JUMP_LABEL = $CONFIG->{jump_label} //= 'preloader_root_' . gen_uuid();

    my $preloads = $CONFIG->{preload} // [];

    # Load Test2::Harness2::Preload lazily so it is not a hard dep for the
    # preloader process itself (harmless, but cleaner).
    require Test2::Harness2::Preload;

    my $meta = Test2::Harness2::Preload->new;

    for my $mod (@$preloads) {
        # Plain-module case: nothing special. If it turns out to declare
        # TEST2_HARNESS_PRELOAD after loading, we pick up its meta-object
        # below.
        my $mod_ok = eval { require(mod2file($mod)); 1 };
        unless ($mod_ok) {
            die "Preloader failed to load '$mod': $@";
        }

        # DSL case: `use Test2::Harness2::Preload` installs TEST2_HARNESS_PRELOAD
        # in the caller. If the module has it after load, merge its stages.
        my $marker = $mod->can('TEST2_HARNESS_PRELOAD') or next;
        my $mod_meta = $marker->();
        next unless $mod_meta;

        $meta->merge($mod_meta);
    }

    $CONFIG->{_meta}             = $meta;
    $CONFIG->{_preload_modules}  = $preloads;

    return;
}

# Entry point invoked when a longjump lands in the main frame. The payload
# is whatever the jumper passed in. Currently two payload kinds are
# understood:
#   { kind => 'launch_test', test_file => $path, env => \%env, ... }
#   anything else -> dump and exit (defensive)
sub _post_jump_launch {
    my ($class, $raw) = @_;

    # Long::Jump::setjump returns an arrayref of the positional values the
    # longjumper passed. Our stage always calls longjump with a single
    # hashref, so unwrap it here.
    my $payload;
    if (ref($raw) eq 'ARRAY' && @$raw && ref($raw->[0]) eq 'HASH') {
        $payload = $raw->[0];
    }
    elsif (ref($raw) eq 'HASH') {
        $payload = $raw;
    }

    my $kind = $payload ? $payload->{kind} : undef;

    if (defined $kind && $kind eq 'launch_test') {
        my $test_file = $payload->{test_file}
            or die "launch_test payload missing test_file";

        # Apply any environment overrides the stage has queued up.
        if (my $env = $payload->{env}) {
            for my $k (keys %$env) {
                $ENV{$k} = $env->{$k};
            }
        }

        # Reset $0 so tools that key off of it see the test file.
        $0 = $test_file;

        # Rewind @ARGV if the caller asked for it.
        @ARGV = @{$payload->{argv} // []};

        # Hand off. goto::file installs a source filter; once it returns
        # and BEGIN unwinds, Perl resumes compiling with the test file's
        # source replacing whatever came next in the -e script. There is
        # nothing after this in the bootstrap, so the filter takes over
        # completely.
        goto::file->import($test_file);
        return;
    }

    warn "Unknown longjump payload kind '" . ($kind // '<undef>') . "'; exiting.\n";
    _exit(255);
}

sub _serve {
    my ($class, $config_file) = @_;

    # Build the object from the config populated in _begin_bootstrap so the
    # IPC service loop has everything it needs.
    my $self = $class->new(
        workdir         => $CONFIG->{workdir},
        name            => $CONFIG->{name} // 'preloader',
        ipcm_info       => $CONFIG->{ipcm_info},
        parent_pids     => $CONFIG->{parent_pids} // [],
        preload_modules => $CONFIG->{_preload_modules},
        meta            => $CONFIG->{_meta},
        jump_label      => $JUMP_LABEL,
    );

    my $exit = $self->run;
    _exit($exit // 0);
}

# ---------------------------------------------------------------------------
# IPC::Manager::Role::Service required accessors.
# ---------------------------------------------------------------------------

sub init {
    my $self = shift;

    $self->{+NAME} //= 'preloader';
    croak "'ipcm_info' is required" unless $self->{+IPCM_INFO};

    $self->{+PARENT_PIDS}         //= [];
    $self->{+WATCH_PIDS_REF}      //= [@{$self->{+PARENT_PIDS}}];
    $self->{+STARTED_STAGE_PIDS}  //= {};
    $self->{+STAGES}              //= {};
    $self->{+PRELOAD_MODULES}     //= [];
}

sub orig_io   { {} }
sub pid       { $_[0]->{+PID} //= $$ }
sub set_pid   { $_[0]->{+PID} = $_[1] }
sub watch_pids { $_[0]->{+WATCH_PIDS_REF} }

# Request dispatcher. Follows the same convention as Test2::Harness2: the
# request envelope has a "request" key that either *is* the handler name or
# is a hashref whose "request" key is.
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

sub request_handler_ping {
    my $self = shift;
    return {ok => 1, pong => $$, name => $self->{+NAME}};
}

sub request_handler_status {
    my $self = shift;

    return {
        ok          => 1,
        name        => $self->{+NAME},
        pid         => $$,
        preloads    => [@{$self->{+PRELOAD_MODULES}}],
        stages      => [sort keys %{$self->{+STAGES} // {}}],
        stage_pids  => {%{$self->{+STARTED_STAGE_PIDS}}},
        jump_label  => $self->{+JUMP_LABEL},
    };
}

sub request_handler_shutdown {
    my $self = shift;
    $self->terminate(0);
    return {ok => 1};
}

# ---------------------------------------------------------------------------
# Service lifecycle hooks.
# ---------------------------------------------------------------------------

sub run_on_start {
    my $self = shift;

    my $meta = $self->{+META};
    return unless $meta;

    my $lookup = $meta->stage_lookup // {};
    $self->{+STAGES} = {%$lookup};

    # Top-level stages are spawned as direct children of the preloader.
    # Nested stages are spawned by their enclosing stage's service, not
    # here.
    require Test2::Harness2::Preloader::Stage;

    for my $stage (@{$meta->stage_list // []}) {
        my $pid = $self->_spawn_stage($stage);
        $self->{+STARTED_STAGE_PIDS}->{$pid} = $stage->name;
    }

    return;
}

sub _spawn_stage {
    my ($self, $stage) = @_;

    return Test2::Harness2::Preloader::Stage->fork_and_run(
        stage_obj      => $stage,
        ipcm_info      => $self->{+IPCM_INFO},
        parent_pid     => $$,
        workdir        => $self->{+WORKDIR},
        preloader_name => $self->{+NAME},
        jump_label     => $self->{+JUMP_LABEL},
    );
}

sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    my $stage_name = delete $self->{+STARTED_STAGE_PIDS}->{$pid};
    return unless defined $stage_name;

    warn "$$ $0 - Preloader stage '$stage_name' (pid $pid) exited (status=$exit); restarting\n";

    my $stage = $self->{+STAGES}->{$stage_name}
        or do {
            warn "$$ $0 - No stage object for '$stage_name'; cannot restart\n";
            return;
        };

    my $new_pid = $self->_spawn_stage($stage);
    $self->{+STARTED_STAGE_PIDS}->{$new_pid} = $stage_name;

    return;
}

sub run_on_cleanup {
    my $self = shift;

    # Ensure any stage services we started are terminated along with us.
    for my $pid (keys %{$self->{+STARTED_STAGE_PIDS} // {}}) {
        kill TERM => $pid;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preloader - Long-running base service that hosts the
preload stage tree and supplies the stack-zero landing test processes
longjump back to.

=head1 DESCRIPTION

The preloader is the root of a service tree the harness uses to run tests
under a pre-warmed interpreter. Its responsibilities:

=over 4

=item *

Exec itself on startup so that its Perl stack starts empty.

=item *

Run the user-supplied list of preload modules. A plain module is simply
C<require>d; a module that C<use>s L<Test2::Harness2::Preload> has its DSL
meta-object merged into this process's master meta-object so stage
metadata is available.

=item *

Install a L<Long::Jump> setjump point at the top of the exec'd script.
Every eventual test process (forked from some stage service that itself
was forked from this preloader) inherits the jump context; a longjump in
the test process unwinds the test's stack all the way back to the
setjump frame, where L<goto::file> hands control to the actual test
file with an effectively empty Perl stack.

=item *

Enter an L<IPC::Manager> service loop and accept requests from the harness
(currently C<ping>, C<status>, C<shutdown>).

=back

Stage subservices are spawned from here in a follow-up task; this module
owns the bootstrap, the jump landing, and the module-loading half of the
preload pipeline.

=head1 SPAWNING

The harness spawns the preloader by fork+exec'ing a canonical one-liner.
The argv for that is produced by L</build_exec_argv>:

    my $cfg_file = Test2::Harness2::Preloader->write_config_file(
        $workdir,
        {
            workdir     => $workdir,
            name        => 'preloader',
            ipcm_info   => $ipcm_info,
            parent_pids => [$parent_pid],
            preload     => ['Moose', 'My::Preload'],
        },
    );

    my @argv = Test2::Harness2::Preloader->build_exec_argv(
        config_file => $cfg_file,
    );
    my $pid = fork // die "fork: $!";
    unless ($pid) { exec @argv or die "exec: $!"; }

=head1 BOOTSTRAP SCRIPT

    use strict;
    use warnings;
    use Test2::Harness2::Preloader;
    BEGIN { Test2::Harness2::Preloader->_begin_bootstrap($ARGV[0]) }
    my $payload = Long::Jump::setjump($Test2::Harness2::Preloader::JUMP_LABEL);
    if ($payload) {
        Test2::Harness2::Preloader->_post_jump_launch($payload);
    }
    else {
        Test2::Harness2::Preloader->_serve($ARGV[0]);
    }

B<Why it is structured this way.> The BEGIN block runs at compile time of
the one-liner, so preload module loading happens before any main-level
statements have cluttered the stack. The C<setjump> call at the top of
the main frame establishes a continuation pointing at effectively zero
stack depth. Any descendant process (a stage service, or a test process
forked from a stage service) inherits that continuation; a C<longjump>
from deep in a stage's message-handling frame unwinds the descendant's
own stack back to the main frame, at which point L<goto::file> hands
control to the test without any harness frames above it.

=head1 REQUEST HANDLERS

=over 4

=item ping

Returns C<{ok =E<gt> 1, pong =E<gt> $pid, name =E<gt> $name}>.

=item status

Returns a snapshot of current state: preloads configured, stages
registered, running stage PIDs, jump-label.

=item shutdown

Terminate the service loop and exit.

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
