package App::Yath2;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Spec ();

use Getopt::Yath::Instance;
use Getopt::Yath::Settings;
use App::Yath2::Options::Yath;

use Object::HashBase qw{
    <script
    <config
    <user_config
    +options
    +settings
};

# The argv field is named explicitly (as opposed to declared via
# Object::HashBase) because Perl reserves the bareword ARGV for its
# magic filehandle and refuses to accept the constant Object::HashBase
# would otherwise generate. Use the string hash key instead; readers
# go through the argv() method below.
sub argv { $_[0]->{argv} }

# Command registry. Keys are command names; values are either the class
# name of the command module (ported) or 1 (stubbed, prints a 'not yet
# implemented' banner). Later stages flip entries as commands land.
my %COMMANDS = (
    test      => 'App::Yath2::Command::test',
    help      => 'App::Yath2::Command::help',
    list      => 'App::Yath2::Command::list',
    which     => 'App::Yath2::Command::which',
    init      => 'App::Yath2::Command::init',
    failed    => 'App::Yath2::Command::failed',
    projects  => 'App::Yath2::Command::projects',
    do        => 'App::Yath2::Command::do',
    start     => 'App::Yath2::Command::start',
    stop      => 'App::Yath2::Command::stop',
    status    => 'App::Yath2::Command::status',
    ping      => 'App::Yath2::Command::ping',
    kill      => 'App::Yath2::Command::kill',
    ps        => 'App::Yath2::Command::ps',
    run       => 'App::Yath2::Command::run',
    spawn     => 'App::Yath2::Command::spawn',
    abort     => 'App::Yath2::Command::abort',
    watch     => 'App::Yath2::Command::watch',
    reload    => 'App::Yath2::Command::reload',
    resources => 'App::Yath2::Command::resources',
);

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

sub options {
    my $self = shift;
    return $self->{+OPTIONS} //= do {
        my $inst = Getopt::Yath::Instance->new(
            category_sort_map => {
                'NO CATEGORY - FIX ME' => 99999,
                'Yath Options'         => -100,
                'Command Options'      => -90,
                'Harness Options'      => -80,
            },
        );
        $inst->include(App::Yath2::Options::Yath->options);
        $inst;
    };
}

sub settings {
    my $self = shift;
    return $self->{+SETTINGS} //= Getopt::Yath::Settings->new;
}

sub run {
    my $self = shift;

    my $argv = [@{$self->{argv} // []}];

    # No args at all - print the top-level usage banner.
    return $self->_print_usage(0) unless @$argv;

    # Pre-command Getopt::Yath pass. stop_at_non_opts halts on the
    # first bare (non-'-') token, which is the command name. That
    # strips recognized yath-level options like -D / --help /
    # --version from the argv before the command parser sees them.
    my $state;
    my $ok = eval {
        $state = $self->options->process_args(
            $argv,
            settings             => $self->settings,
            stop_at_non_opts     => 1,
            skip_posts           => 1,
            invalid_opt_callback => sub {
                my ($opt) = @_;
                die "'$opt' is not a valid yath option.\n";
            },
        );
        1;
    };
    my $err = $@;
    unless ($ok) {
        chomp($err);
        $self->_print_to(\*STDERR, "$err\n\n");
        $self->_print_usage(\*STDERR);
        return 2;
    }

    my $yath = $self->settings->group('yath', 1);

    # --version / -V: print and exit.
    return $self->_print_version(0) if ${$yath->option_ref('version', 1)};

    # --help / -h / --help=GROUP: print help and exit.
    my $help_val = ${$yath->option_ref('help', 1)};
    if (defined $help_val) {
        my $group = ($help_val eq '1') ? undef : $help_val;
        return $self->_print_help(0, group => $group);
    }

    my $cmd     = $state->{stop};
    my $remains = $state->{remains} // [];

    # Nothing left after options pass means 'yath -D' or similar with
    # no command. Treat it the same as 'yath' with no args: print
    # the top-level usage.
    unless (defined $cmd) {
        return $self->_print_usage(0);
    }

    # 'help' subcommand (Stage 6 will wire this to command-specific
    # help; for now it is the same as top-level help).
    if ($cmd eq 'help') {
        my $target = $remains->[0];
        if (defined $target && exists $COMMANDS{$target}) {
            # Stage 6 — `yath help <cmd>` should show per-command
            # options. For now just print top-level usage and note
            # the limitation.
            $self->_print_to(
                \*STDOUT,
                "yath2: per-command help is not yet wired (Stage 6).\n",
                "Showing top-level usage instead.\n\n",
            );
        }
        return $self->_print_usage(0);
    }

    if (exists $COMMANDS{$cmd}) {
        my $target = $COMMANDS{$cmd};

        if ($target eq '1') {
            $self->_print_to(
                \*STDERR,
                "yath2: the '$cmd' command has not been ported yet in this rewrite.\n",
                "See PLAN for the planned port order; until then this command is not available.\n",
            );
            return 2;
        }

        return $self->_dispatch($target, $remains);
    }

    $self->_print_to(\*STDERR, "yath2: unknown command '$cmd'.\n\n");
    $self->_print_usage(\*STDERR);
    return 2;
}

sub _dispatch {
    my $self = shift;
    my ($class, $cmd_argv) = @_;

    my $file = $class;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    my $ok = eval { require $file; 1 };
    unless ($ok) {
        my $err = $@;
        $self->_print_to(\*STDERR, "yath2: failed to load '$class': $err");
        return 2;
    }

    my $cmd = $class->new(
        script      => $self->{+SCRIPT},
        argv        => $cmd_argv,
        config      => $self->{+CONFIG},
        user_config => $self->{+USER_CONFIG},
    );

    return $cmd->run;
}

sub _print_version {
    my $self   = shift;
    my ($exit) = @_;
    my $script = $self->_display_script;
    $self->_print_to(\*STDOUT, "$script (App::Yath2 $VERSION)\n");
    return $exit;
}

sub _print_help {
    my $self = shift;
    my ($exit_or_fh, %params) = @_;

    my $fh   = ref($exit_or_fh) ? $exit_or_fh : \*STDOUT;
    my $exit = ref($exit_or_fh) ? 0           : ($exit_or_fh // 0);

    my $group = $params{group};

    # When a group is requested, render just that group's option
    # docs via Getopt::Yath. Unknown groups return a '!! Invalid
    # option group !!' sentinel which we normalize into a 2-exit
    # error to STDERR.
    if (defined $group) {
        my $options = $self->options;
        unless ($options->have_group($group)) {
            $self->_print_to(
                \*STDERR,
                "yath2: unknown option group '$group'.\n",
                "Known groups: ", join(', ' => sort keys %{$options->option_groups}), "\n",
            );
            return 2;
        }

        my $docs = $options->docs(
            'cli',
            group    => $group,
            settings => $self->settings,
            color    => 0,
        );
        $self->_print_to($fh, "$docs\n");
        return $exit;
    }

    # No group: full usage banner plus the docs for all top-level
    # yath options.
    $self->_print_usage($fh);

    my $docs = $self->options->docs(
        'cli',
        settings => $self->settings,
        color    => 0,
    );
    $self->_print_to($fh, "$docs\n") if defined $docs && length $docs;

    return $exit;
}

sub _print_usage {
    my $self = shift;
    my ($exit_or_fh) = @_;

    my $fh   = ref($exit_or_fh) ? $exit_or_fh : \*STDOUT;
    my $exit = ref($exit_or_fh) ? 0           : ($exit_or_fh // 0);

    my $script = $self->_display_script;
    my @cmds   = sort keys %COMMANDS;

    $self->_print_to(
        $fh,
        "USAGE: $script [YATH OPTIONS] [COMMAND [ARGS...]]\n",
        "\n",
        "App::Yath2 (version $VERSION) is the V2 application layer for the yath\n",
        "test harness.  It is under active development; no command has been\n",
        "ported yet in this rewrite.\n",
        "\n",
        "Planned commands (all currently stubbed):\n",
        (map { "  $_\n" } @cmds),
        "\n",
        "See PLAN in the repository root for the port schedule.\n",
        "Run 'yath --help=GROUP' to see options for a single group.\n",
    );

    return $exit;
}

sub _display_script {
    my $self   = shift;
    my $script = $self->{+SCRIPT} // $0 // 'yath';
    # Abs2rel can throw if CWD is weird; fall back to the raw path.
    my $rel = eval { File::Spec->abs2rel($script) };
    return defined($rel) && length($rel) ? $rel : $script;
}

sub _print_to {
    my $self = shift;
    my ($fh, @parts) = @_;
    print {$fh} @parts;
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2 - Top-level application class for the V2 yath rewrite.

=head1 DESCRIPTION

C<App::Yath2> is the command-dispatch shell for the V2 rewrite of the
yath test harness. The shared C<yath> launcher from
C<App-Yath-Script> reaches this class via
L<App::Yath::Script::V2>. C<App::Yath2> parses the top-level C<argv>
with L<Getopt::Yath>, handles C<--help> / C<--help=GROUP> /
C<--version>, strips recognized yath-level options like C<-D> from
the argv, and then dispatches to the requested command.

At present (Stage 4 of the feature parity plan) no commands are
ported. Every command name in the registry prints a
'not yet implemented' banner and exits with a non-zero code.

=head1 SYNOPSIS

    my $app = App::Yath2->new(
        script      => '/path/to/yath',
        argv        => \@ARGV,
        config      => '/path/to/.yath.rc',
        user_config => '/path/to/.yath.user.rc',
    );

    exit($app->run);

=head1 ATTRIBUTES

=over 4

=item $app->script

Absolute path to the script that was executed (the C<yath> launcher).

=item $app->argv

Arrayref of the arguments the launcher received.

=item $app->config

Path to the discovered C<.yath.rc> file, or C<undef> if none.

=item $app->user_config

Path to the discovered C<.yath.user.rc> file, or C<undef> if none.

=item $app->options

The L<Getopt::Yath::Instance> containing every yath-level option
definition. Lazily constructed.

=item $app->settings

The L<Getopt::Yath::Settings> object parsed option values are written
into. Lazily constructed.

=back

=head1 METHODS

=over 4

=item $exit = $app->run

Parse L</argv>, dispatch, and return the integer exit code.

=over 4

=item * No args: print usage, exit 0.

=item * C<--help> / C<-h>: print usage + top-level option docs, exit 0.

=item * C<--help=GROUP>: print docs for a single option group,
exit 0; exit 2 with an error if GROUP is unknown.

=item * C<--version> / C<-V>: print version, exit 0.

=item * Invalid top-level option: print error + usage to STDERR,
exit 2.

=item * Known command name (anything in the stubbed registry): print
'not yet implemented' to STDERR, exit 2.

=item * Anything else: print 'unknown command' + usage to STDERR,
exit 2.

=back

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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
