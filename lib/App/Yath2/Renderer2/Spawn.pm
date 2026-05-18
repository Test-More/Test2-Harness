package App::Yath2::Renderer2::Spawn;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use IO::Handle  ();
use File::Spec  ();
use POSIX       ();
use Time::HiRes ();

use App::Yath2::Log();
use App::Yath2::Renderer2::Loop();
use App::Yath2::Renderer2::Registry();
use App::Yath2::Renderer2::TerminalAuto();

# Fork one renderer child per spec. Each child runs
# App::Yath2::Renderer2::Loop::run against the supplied log directory,
# rendering through a single renderer instance.
#
# Args (key/value):
#   logdir       => path to the live or sealed log directory
#   settings     => parsed yath Settings (used for verbosity defaults)
#   specs        => arrayref of spec hashrefs from
#                   App::Yath2::Options::Renderer->renderer_specs
#   parent_pid   => optional, pid to embed in child for liveness watching
#   command_pid  => optional, defaults to current pid
#   ipc_endpoint => optional, path to a JSON ipc endpoint info file
#   stop_run_id  => optional, ignored by the new loop (live-vs-sealed
#                   is decided by the Log backend); accepted for
#                   caller-side parity with the legacy interface.
#
# Returns an arrayref of pids in the parent. Never returns in a child
# (each child POSIX::_exits after its loop completes).
sub spawn_renderers {
    my (%args) = @_;
    my $logdir = $args{logdir} // croak "spawn_renderers: logdir is required";
    my $specs  = $args{specs}  // croak "spawn_renderers: specs is required";
    croak "spawn_renderers: specs must be an arrayref" unless ref($specs) eq 'ARRAY';

    my @pids;
    for my $spec (@$specs) {
        my $pid = fork() // die "Could not fork renderer: $!";
        if ($pid) {
            push @pids, $pid;
            next;
        }

        # Child: clear any inherited Spawn-ownership flag so its DESTROY
        # cannot race with the parent's lifecycle management. Renderer
        # processes do not own the harness.
        if (my $sp = $args{spawn}) {
            eval { $sp->clear_terminate_on_destroy; 1 };
        }

        my $exit = 0;
        my $ok   = eval {
            $exit = _run_one_renderer(
                spec         => $spec,
                logdir       => $logdir,
                settings     => $args{settings},
                parent_pid   => $args{parent_pid},
                command_pid  => $args{command_pid} // $$,
                ipc_endpoint => $args{ipc_endpoint},
                live         => $args{live} ? 1 : 0,
            );
            1;
        };
        unless ($ok) {
            my $err = $@;
            print STDERR "Renderer child ($spec->{name}) died: $err\n";
            POSIX::_exit(2);
        }
        POSIX::_exit($exit // 0);
    }

    return \@pids;
}

# Run exactly one renderer end-to-end in the current (child) process.
# Splits the renderer construction off so the fork wrapper above stays
# focused on process plumbing.
sub _run_one_renderer {
    my (%args) = @_;
    my $spec   = $args{spec};
    my $logdir = $args{logdir};

    # live => $dir is the right dispatcher for an in-flight workdir/logs
    # directory; auto => $dir would land on the sealed Directory
    # backend (which does not poll the LIVE sentinel). For sealed
    # replays the standalone `yath render` command is the entry
    # point, not this spawn helper.
    my $log = $args{live}
        ? App::Yath2::Log->new(live => $logdir)
        : App::Yath2::Log->new(auto => $logdir);

    my $renderer_settings = _build_renderer_settings(
        spec     => $spec,
        settings => $args{settings},
    );

    my $out_fh = $renderer_settings->{_out_fh};

    my %ctor = (
        log          => $log,
        ipc_endpoint => $args{ipc_endpoint},
        parent_pid   => $args{parent_pid},
        command_pid  => $args{command_pid},
        out_fh       => $out_fh,
        settings     => $renderer_settings,
    );

    my $renderer = $spec->{class}->new(%ctor);
    $renderer->connect_ipc($args{ipc_endpoint})
        if defined $args{ipc_endpoint} && length $args{ipc_endpoint};

    App::Yath2::Renderer2::Loop::run($renderer);
    return 0;
}

# Build the per-renderer settings hash. Mirrors the resolution logic
# previously embedded in Command::render so that fan-out from test /
# run / replay matches the standalone `yath render` invocation:
#
#   - Pass through the renderer's own option-group values as both
#     top-level keys and as a sub-hash under the group name.
#   - Resolve out_fh from the renderer's --<prefix>-out option (or
#     STDOUT when unset / "-").
#   - For the Terminal renderer, instantiate a formatter (TerminalAuto
#     picks txt vs tty by tty-ness of out_fh) when one was not
#     explicitly requested.
#   - For the JUnit renderer, alias the flat `out` value into the
#     legacy `junit_out` key the renderer reads from.
sub _build_renderer_settings {
    my (%args) = @_;
    my $spec     = $args{spec};
    my $settings = $args{settings};

    my $renderer_class = $spec->{class};
    my $short_name     = $spec->{name};

    my %out;

    if ($renderer_class->can('options') && defined $settings) {
        my $instance = $renderer_class->options;
        my @opts     = @{$instance->options};
        if (@opts) {
            my $group_name = $opts[0]->group;
            if ($settings->check_group($group_name)) {
                my $group = $settings->$group_name;
                for my $opt (@opts) {
                    my $field = $opt->field;
                    $out{$field} = $group->$field;
                }
                $out{$group_name} = {
                    map { my $f = $_->field; ($f => $group->$f) } @opts
                };
            }
        }
    }

    # Fold in shared renderer defaults (verbose, quiet, theme, wrap)
    # so renderers that consult them without their own per-prefix
    # override can still find sensible values.
    if (defined $settings && $settings->check_group('renderer')) {
        my $rs = $settings->renderer;
        $out{verbose}    //= $rs->verbose;
        $out{quiet}      //= $rs->quiet;
        $out{theme}      //= $rs->theme;
        $out{wrap}       //= $rs->wrap;
        $out{show_times} //= $rs->show_times;
        $out{qvf}        //= $rs->qvf;
    }

    my $out_fh = _resolve_out_fh($out{out});
    $out{_out_fh} = $out_fh;

    if ($renderer_class eq 'App::Yath2::Renderer2::Terminal'
        || ($short_name // '') eq 'terminal-auto')
    {
        my $name_or_class = $out{formatter};
        if (defined $name_or_class && length $name_or_class) {
            $out{formatter} = _instantiate_formatter($name_or_class, $out_fh);
        }
        else {
            $out{formatter} = App::Yath2::Renderer2::TerminalAuto::pick(out_fh => $out_fh);
        }
    }

    if ($renderer_class eq 'App::Yath2::Renderer2::JUnit') {
        $out{junit_out} //= $out{out} if defined $out{out} && length $out{out};
    }

    return \%out;
}

sub _resolve_out_fh {
    my ($path) = @_;
    return \*STDOUT if !defined($path) || !length($path) || $path eq '-';

    open(my $fh, '>', $path) or croak "cannot open '$path' for renderer output: $!";
    $fh->autoflush(1) if $fh->can('autoflush');
    return $fh;
}

# Map a formatter short name ("txt", "tty") or "+Fully::Qualified" to a
# loaded class. Caller-supplied class names without "+" or the App::
# prefix get the namespace applied.
sub _instantiate_formatter {
    my ($name, $out_fh) = @_;

    my $class;
    if ($name =~ /^\+(.+)/) {
        $class = $1;
    }
    elsif ($name =~ /^App::/) {
        $class = $name;
    }
    else {
        my $title = ucfirst lc $name;
        $class = "App::Yath2::Formatter::$title";
    }

    require Test2::Harness2::Util;
    my $file = Test2::Harness2::Util::mod2file($class);
    require $file unless $INC{$file};

    return $class->new(color_mode => 'auto') if $class eq 'App::Yath2::Formatter::Tty';
    return $class->new;
}

# Reap a list of renderer child pids in order. Returns the aggregate
# exit status: 0 when every child exited 0, the first non-zero status
# otherwise.
#
# Optional %args:
#   signal_first => 1   Send SIGTERM to every pid before the blocking
#                       waitpid loop. Use this when the renderers are
#                       still actively rendering and the parent has
#                       decided the run is over -- they have no other
#                       in-band signal that this iteration ended
#                       (LIVE is still in place, command_pid is still
#                       alive). The SIGTERM default handler exits the
#                       child cleanly.
#   grace        => N   Seconds to wait between SIGTERM and SIGKILL
#                       (default 5).
sub reap_renderers {
    my (%args) = @_;
    my $pids = $args{pids} or return 0;
    return 0 unless ref($pids) eq 'ARRAY' && @$pids;

    if ($args{signal_first}) {
        for my $pid (@$pids) {
            next unless $pid;
            next unless kill(0, $pid);
            kill(TERM => $pid);
        }
    }

    my $grace    = $args{grace} // 5;
    my $deadline = $args{signal_first} ? (Time::HiRes::time() + $grace) : undef;

    my $worst = 0;
    my @remaining = grep { defined && $_ } @$pids;
    while (@remaining) {
        my @still;
        for my $pid (@remaining) {
            my $kid = waitpid($pid, POSIX::WNOHANG());
            if ($kid == $pid) {
                my $exit = _exit_from_status($? // 0, $args{signal_first});
                $worst = $exit if $exit && !$worst;
                next;
            }
            push @still, $pid;
        }
        last unless @still;
        @remaining = @still;

        if ($deadline && Time::HiRes::time() >= $deadline) {
            # Hard timeout: SIGKILL and reap unconditionally.
            for my $pid (@remaining) {
                kill(KILL => $pid);
                waitpid($pid, 0);
            }
            last;
        }

        Time::HiRes::sleep(0.05);
    }
    return $worst;
}

# Translate a $? status into a single integer exit code, treating
# signal-driven termination specially:
#
#   - status == 0                : 0  (clean exit)
#   - signal_first && killed by  : 0  (we asked it to die; not an error)
#                  SIGTERM/SIGINT
#   - otherwise                  : ($? >> 8) || ($? & 0x7f) so a real
#                                   failure surfaces as nonzero
sub _exit_from_status {
    my ($status, $signal_first) = @_;
    return 0 if $status == 0;

    my $sig = $status & 0x7f;
    if ($sig) {
        return 0 if $signal_first && ($sig == 15 || $sig == 2); # TERM/INT
        return $sig;
    }
    return $status >> 8;
}

# Non-blocking poll: return 1 only when every renderer child has been
# reaped. Mutates $pids in place to remove already-reaped entries.
sub renderers_all_reaped {
    my (%args) = @_;
    my $pids = $args{pids} or return 1;
    return 1 unless ref($pids) eq 'ARRAY' && @$pids;

    my @remaining;
    for my $pid (@$pids) {
        next unless $pid;
        my $kid = waitpid($pid, POSIX::WNOHANG());
        if ($kid == $pid) {
            # reaped; drop
            next;
        }
        push @remaining, $pid;
    }
    @$pids = @remaining;
    return @remaining ? 0 : 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer2::Spawn - Fork one renderer child per active renderer.

=head1 SYNOPSIS

    use App::Yath2::Options::Renderer ();
    use App::Yath2::Renderer2::Spawn  qw//;

    my $specs = App::Yath2::Options::Renderer->renderer_specs($settings);

    my $pids = App::Yath2::Renderer2::Spawn::spawn_renderers(
        logdir      => "$workdir/logs",
        specs       => $specs,
        settings    => $settings,
        parent_pid  => $harness_pid,
        command_pid => $$,
    );

    # ... let the harness do its work ...

    my $exit = App::Yath2::Renderer2::Spawn::reap_renderers(pids => $pids);

=head1 DESCRIPTION

C<App::Yath2::Renderer2::Spawn> is the shared fan-out helper used by
C<yath test>, C<yath run>, C<yath replay>, and C<yath watch> to fork
one renderer child per active renderer. Each child constructs a single
renderer instance and drives it via L<App::Yath2::Renderer2::Loop>.

The active set is taken from
L<App::Yath2::Options::Renderer/renderer_specs>, which resolves short
names (C<terminal>, C<terminal-auto>, C<junit>) through
L<App::Yath2::Renderer2::Registry>.

=head1 FUNCTIONS

=over 4

=item $pids = App::Yath2::Renderer2::Spawn::spawn_renderers(%args)

Fork one child per spec. Returns an arrayref of child pids in the
parent; never returns in a child (each child C<POSIX::_exit>s after
its loop completes).

Required args:

=over 4

=item logdir => PATH

Path to the live or sealed log directory.

=item specs => [ \%spec, ... ]

Output of L<App::Yath2::Options::Renderer/renderer_specs>.

=back

Optional args:

=over 4

=item settings

Parsed C<Getopt::Yath> Settings — used to look up shared verbosity
defaults and the renderer's own option group.

=item parent_pid / command_pid

PIDs the child watches via C<kill 0> for the third shutdown-detection
layer. C<command_pid> defaults to the current process's PID.

=item ipc_endpoint

Path to a JSON IPC endpoint info file. When set, the child calls
C<connect_ipc> on its renderer so the parent can signal a clean stop
out-of-band.

=item spawn

Optional L<Test2::Harness2::Spawn> handle. When supplied the child
calls C<clear_terminate_on_destroy> on it before driving the loop so a
child-side DESTROY does not race with the parent's lifecycle
management.

=back

=item $exit = App::Yath2::Renderer2::Spawn::reap_renderers(pids => $pids)

Wait for every renderer child to exit. Returns the first non-zero exit
status seen, or 0 when all children exited cleanly.

=item $bool = App::Yath2::Renderer2::Spawn::renderers_all_reaped(pids => $pids)

Non-blocking variant. Reaps any children that have already exited
(modifying C<$pids> in place to drop them) and returns 1 only when no
children remain.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
