package App::Yath2::Command::render;
use strict;
use warnings;

our $VERSION = '2.000013';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use Carp qw/croak/;

use App::Yath2::Log();
use App::Yath2::Renderer::Registry();
use App::Yath2::Renderer::Loop();
use App::Yath2::Renderer::TerminalAuto();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

option_group {group => 'render', category => 'Render Command Options'} => sub {
    option ipc_endpoint => (
        type           => 'Scalar',
        description    => 'Path to the parent IPC endpoint info file. The renderer connects back to receive an out-of-band shutdown signal.',
        long_examples  => [' PATH'],
        short_examples => [' PATH'],
    );

    option parent_pid => (
        type           => 'Scalar',
        description    => 'PID of the parent (collector) process. The renderer watches this PID and drains when it disappears.',
        long_examples  => [' N'],
        short_examples => [' N'],
    );

    option command_pid => (
        type           => 'Scalar',
        description    => 'PID of the originating command process. The renderer watches this PID and drains when it disappears.',
        long_examples  => [' N'],
        short_examples => [' N'],
    );

    option reformat => (
        type        => 'Bool',
        default     => 0,
        description => 'Rebuild any stale formatter artifacts in the log during this invocation. Requires a writable log; errors out on read-only sources (tarball, sqlite). For read-only sources, use "yath reformat LOG OUTLOG" instead.',
    );

    option criticality => (
        type           => 'Scalar',
        description    => 'Override the renderer\'s default criticality. Accepts "best_effort" or "required".',
        long_examples  => [' best_effort', ' required'],
        short_examples => [' best_effort', ' required'],
    );
};

# Make every renderer's flat option group visible to the parser. This
# happens at compile time so prefix conflicts surface during command
# load rather than mid-parse. See App::Yath2::Renderer::Registry for
# the ownership rules.
App::Yath2::Renderer::Registry->include_all_renderer_options(__PACKAGE__->options);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 0 }
sub group              { 'log parsing' }
sub summary            { 'Run a single renderer against a log' }

sub cli_args { "[--] RENDERER LOG" }

sub description {
    return <<"    EOT";
Run a single renderer process against a log. The first positional
argument is the renderer short name (e.g. "terminal", "junit") or a
fully-qualified Perl class prefixed with "+". The second is the log
path (a sealed log directory or a .yath archive); if omitted, the
most recent log is used.

This command is the canonical way to spawn one renderer; "yath test",
"yath run", and "yath replay" fan out via this command internally,
one child per active renderer. Renderer-specific flat options
(e.g. --junit-out, --terminal-verbose) are accepted alongside the
command-level options below.

Exit code: 0 when the renderer completes cleanly; non-zero when a
"required" renderer fails or when the renderer's internal validation
errors out.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];
    shift @$args if @$args && $args->[0] eq '--';

    my $name = shift @$args;
    die "Usage: yath render RENDERER [LOG]\n"
        unless defined $name && length $name;

    my $path = shift @$args;
    unless (defined $path && length $path) {
        $path = App::Yath2::Log->find_latest($settings);
        print STDERR "yath render: using latest log: $path\n"
            if defined $path && length $path;
    }

    die "Usage: yath render RENDERER LOG\n"
        unless defined $path && length $path;

    die "Log source '$path' does not exist\n"
        unless -e $path;

    die "extra arguments after LOG\n" if @$args;

    my ($renderer_class, $prefix) = App::Yath2::Renderer::Registry->resolve_and_load($name);

    my $log = App::Yath2::Log->new(auto => $path);

    my $rs = $settings->render;

    # --reformat is incompatible with read-only logs (tarball, sqlite).
    # Direct the user at the standalone reformat command for those.
    if ($rs->reformat && !_log_is_writable($log)) {
        die "--reformat requires a writable log (live or directory). " . "For read-only logs (tarball, sqlite), use 'yath reformat LOG OUTLOG' instead.\n";
    }

    # Resolve out_fh + formatter for renderers that need a default.
    # Terminal renderer takes both via its own settings hash; JUnit
    # writes its own file and doesn't need either.
    my $renderer_settings = _build_renderer_settings($renderer_class, $prefix, $settings, $name);

    my %ctor_args = (
        log          => $log,
        ipc_endpoint => $rs->ipc_endpoint,
        parent_pid   => $rs->parent_pid,
        command_pid  => $rs->command_pid,
        out_fh       => $renderer_settings->{_out_fh},
        settings     => $renderer_settings,
    );
    $ctor_args{criticality} = $rs->criticality if defined $rs->criticality && length $rs->criticality;

    my $renderer = $renderer_class->new(%ctor_args);

    # Connect IPC if an endpoint was supplied. connect_ipc is a no-op
    # when undef/empty; we still call it for symmetry with the parent
    # contract.
    $renderer->connect_ipc($rs->ipc_endpoint) if defined $rs->ipc_endpoint && length $rs->ipc_endpoint;

    App::Yath2::Renderer::Loop::run($renderer);

    return 0;
}

# Probe whether the Log backend accepts artifact writes. Directory and
# Live backends are writable; TarZIdx and DB are not. We use a class-
# name check rather than a Role method to avoid expanding the public
# Log role contract just for this single call site.
sub _log_is_writable {
    my $log   = shift;
    my $class = ref($log);

    return 1 if $class eq 'App::Yath2::Log::Live';
    return 1 if $class eq 'App::Yath2::Log::Directory';

    # TarZIdx, DB, and anything else: read-only.
    return 0;
}

# Build the renderer's settings hash from the parsed Settings object.
# We pass through everything from the renderer's flat option group as
# top-level keys (so existing renderers that read $settings->{foo} keep
# working), plus a few derived defaults (formatter, _out_fh) that the
# Terminal renderer expects.
sub _build_renderer_settings {
    my ($renderer_class, $prefix, $settings, $short_name) = @_;

    my %out;

    if ($renderer_class->can('options')) {
        my $instance = $renderer_class->options;
        my @opts     = @{$instance->options};
        if (@opts) {
            my $group_name = $opts[0]->group;
            if ($settings->check_group($group_name)) {
                my $group = $settings->$group_name;
                for my $opt (@opts) {
                    my $field = $opt->field;
                    my $v     = $group->$field;
                    $out{$field} = $v;
                }
                # Also surface the entire group hash under the group
                # name, for renderers that prefer $s->{junit}{out} over
                # the flat $s->{out} key.
                $out{$group_name} = {map { my $f = $_->field; ($f => $group->$f) } @opts};
            }
        }
    }

    # Resolve out_fh: --terminal-out PATH if given and not "-", else STDOUT.
    my $out_fh = _resolve_out_fh($out{out});
    $out{_out_fh} = $out_fh;

    # Terminal renderer expects 'formatter' to be a formatter instance
    # under $settings->{formatter}. Pick the default if no explicit
    # formatter was requested (or normalise a short name into a class).
    if ($renderer_class eq 'App::Yath2::Renderer::Terminal'
        || ($short_name // '') eq 'terminal-auto')
    {
        my $name_or_class = $out{formatter};
        if (defined $name_or_class && length $name_or_class) {
            $out{formatter} = _instantiate_formatter($name_or_class, $out_fh);
        }
        else {
            $out{formatter} = App::Yath2::Renderer::TerminalAuto::pick(out_fh => $out_fh);
        }
        # Map terminal.verbose -> verbose so Terminal->_verbose finds it.
        $out{verbose} //= $out{verbose};
    }

    # JUnit renderer reads $s->{junit_out}; alias the flat junit.out
    # value into the legacy key so the existing renderer code keeps
    # working without further changes.
    if ($renderer_class eq 'App::Yath2::Renderer::JUnit') {
        $out{junit_out} //= $out{out} if defined $out{out} && length $out{out};
    }

    return \%out;
}

# --terminal-out: "-" or undef means STDOUT; any other value opens a
# real file for the renderer to write to. Croaks on open failure so
# the misconfiguration surfaces before the loop starts.
sub _resolve_out_fh {
    my ($path) = @_;
    return \*STDOUT if !defined($path) || !length($path) || $path eq '-';

    open(my $fh, '>', $path) or croak "cannot open '$path' for renderer output: $!";
    $fh->autoflush(1) if $fh->can('autoflush');
    return $fh;
}

# Map a formatter short name ("txt", "tty") or a "+Fully::Qualified"
# class spec to an instance. Caller-supplied class names that don't
# start with "+" or "App::Yath2::Formatter::" get the namespace
# prepended; "+" is stripped before requiring.
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
        # "txt" -> "App::Yath2::Formatter::Txt"
        my $title = ucfirst lc $name;
        $class = "App::Yath2::Formatter::$title";
    }

    require Test2::Harness2::Util;
    my $file = Test2::Harness2::Util::mod2file($class);
    require $file unless $INC{$file};

    # Tty wants color_mode at construction time; pass 'auto' so it
    # auto-detects from the out_fh isatty check.
    if ($class eq 'App::Yath2::Formatter::Tty') {
        return $class->new(color_mode => 'auto');
    }
    return $class->new;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::render - Run a single renderer against a log.

=head1 SYNOPSIS

    # Recommended one-off use: drive a renderer through `yath replay`,
    # which fans out to this command internally.
    yath replay PATH/TO/LOG

    # Direct invocation: spawn one renderer.
    yath render terminal PATH/TO/LOG
    yath render junit    PATH/TO/LOG --junit-out=results.xml
    yath render +My::Renderer PATH/TO/LOG

=head1 DESCRIPTION

This is the canonical command that runs exactly one
L<App::Yath2::Renderer> subclass against a log. C<yath test>,
C<yath run>, and C<yath replay> fan out to this command internally,
spawning one child process per active renderer. Each renderer process
owns its own log iteration, its own FileMonitor watches, and its own
output sink.

=head2 Positional arguments

    yath render RENDERER LOG

C<RENDERER> is either a short renderer name registered in
L<App::Yath2::Renderer::Registry> (C<terminal>, C<terminal-auto>,
C<junit>) or a fully-qualified Perl class prefixed with C<+>.

C<LOG> is a sealed log directory or a C<.yath> archive. The C<auto>
backend dispatch in L<App::Yath2::Log> figures out which backend to
use. If omitted, the most recent log is selected via
L<< App::Yath2::Log/find_latest >>.

=head2 Flat-namespaced options

Each renderer exposes a flat option group. Two examples:

    --terminal-verbose          # Terminal renderer
    --junit-out=results.xml     # JUnit renderer

Prefix ownership is enforced at registration time: two renderers
cannot register the same prefix.

=head2 Read-only logs and C<--reformat>

C<--reformat> rebuilds any stale formatter artifacts in the log while
this renderer is running. It requires a writable log (live or
directory). For read-only logs (tarball, sqlite), use C<yath reformat
LOG OUTLOG> instead, which writes the rebuilt artifacts to a new
copy.

=head2 IPC and PID arguments

C<--ipc-endpoint>, C<--parent-pid>, and C<--command-pid> are normally
filled in by the parent command when it fans out to renderer
children. Manual users typically leave them unset.

=head1 EXIT CODE

0 on clean completion. Non-zero when the renderer's internal validation
(e.g. JUnit's required-output-path check) errors out before the loop
begins, or when a C<required> renderer fails.

=head1 SEE ALSO

L<App::Yath2::Renderer::Loop>,
L<App::Yath2::Renderer::Registry>,
L<App::Yath2::Command::reformat>,
L<App::Yath2::Command::replay>.

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
