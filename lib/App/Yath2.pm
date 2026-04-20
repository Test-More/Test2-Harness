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

use constant _ARGV => 'argv';

# The argv field is named explicitly (as opposed to declared via
# Object::HashBase) because Perl reserves the bareword ARGV for its
# magic filehandle and refuses to accept the constant Object::HashBase
# would otherwise generate. Use the _ARGV constant instead; readers
# go through the argv() method below.
sub argv { $_[0]->{+_ARGV} }

sub init {
    my $self = shift;
    # Use _ARGV constant here
    $self->{+_ARGV} //= [];
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

sub load_command {
    my $self = shift;
    my ($name) = @_;

    return undef unless defined $name && $name =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;

    my $class = "App::Yath2::Command::$name";
    my $file  = $class;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    return undef unless eval { require $file; 1 };
    return undef unless $class->isa('App::Yath2::Command');

    return $class;
}

sub run {
    my $self = shift;

    my $argv = [@{$self->{+_ARGV} // []}];

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
        if (defined $target && $self->load_command($target)) {
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

    if (my $cmd_class = $self->load_command($cmd)) {
        # Stage 5 wires the real dispatch. Until then the command
        # class loads but nothing else is hooked up; acknowledge
        # that and exit.
        $self->_print_to(
            \*STDERR,
            "yath2: the '$cmd' command resolved to $cmd_class, but command dispatch\n",
            "is not yet wired in this stage. See PLAN for the port schedule.\n",
        );
        return 2;
    }

    $self->_print_to(\*STDERR, "yath2: unknown command '$cmd'.\n\n");
    $self->_print_usage(\*STDERR);
    return 2;
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

    $self->_print_to(
        $fh,
        "USAGE: $script [YATH OPTIONS] [COMMAND [ARGS...]]\n",
        "\n",
        "App::Yath2 (version $VERSION) is the V2 application layer for the yath\n",
        "test harness.  It is under active development; no command has been\n",
        "ported yet in this rewrite.\n",
        "\n",
        "A command <CMD> is available whenever App::Yath2::Command::<CMD> can be\n",
        "loaded from \@INC. See PLAN in the repository root for the in-dist port\n",
        "schedule.  Run 'yath --help=GROUP' to see options for a single group.\n",
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

A command C<< <CMD> >> is recognized whenever
C<< App::Yath2::Command::<CMD> >> can be loaded from C<@INC> and
subclasses C<App::Yath2::Command>. This makes the command set an open
extension point: third-party distributions can ship new commands by
shipping modules in that namespace. At present (Stage 4 of the feature
parity plan) no commands are ported; any command name resolves to
'unknown command'.

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

=item * Command name whose class loads (C<App::Yath2::Command::$name>
and C<< ->isa('App::Yath2::Command') >>): Stage 5 wires real
dispatch; Stage 4 prints a 'dispatch not yet wired' banner and exits
2.

=item * Anything else: print 'unknown command' + usage to STDERR,
exit 2.

=back

=item $class = $app->load_command($name)

Return C<App::Yath2::Command::$name> if that module can be required
and is a subclass of C<App::Yath2::Command>; C<undef> otherwise. The
command set is open -- any distribution can ship
C<App::Yath2::Command::*> modules and they will dispatch.

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
