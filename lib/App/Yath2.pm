package App::Yath2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();

use Object::HashBase qw{
    <script
    <config
    <user_config
};

# The argv field is named explicitly (as opposed to declared via
# Object::HashBase) because Perl reserves the bareword ARGV for its
# magic filehandle and refuses to accept the constant Object::HashBase
# would otherwise generate. Use the string hash key instead; readers
# go through the argv() method below.
sub argv { $_[0]->{argv} }

# Minimal command registry. Keys are command names; values are either
# 1 (reserved, not yet ported) or a module name (once ported). At this
# stage only --help / --version are wired; every command name listed
# here prints the 'not yet implemented' banner. Later stages flip
# entries to real command classes as they land.
my %COMMANDS = (
    test      => 1,
    list      => 1,
    help      => 1,
    init      => 1,
    failed    => 1,
    start     => 1,
    stop      => 1,
    status    => 1,
    ping      => 1,
    kill      => 1,
    ps        => 1,
    run       => 1,
    spawn     => 1,
    abort     => 1,
    watch     => 1,
    reload    => 1,
    resources => 1,
    which     => 1,
    projects  => 1,
    do        => 1,
);

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

sub run {
    my $self = shift;

    my $argv = $self->{argv};

    # No args at all - print the top-level usage banner.
    return $self->_print_usage(0) unless @$argv;

    my $first = $argv->[0];

    return $self->_print_version(0)
        if $first eq '--version' || $first eq '-V';

    return $self->_print_usage(0)
        if $first eq '--help' || $first eq '-h' || $first eq 'help';

    if ($first =~ m/^-/) {
        $self->_print_to(\*STDERR, "Unknown top-level option: $first\n\n");
        $self->_print_usage(\*STDERR);
        return 2;
    }

    # Treat the first non-option argument as the command name.
    if (exists $COMMANDS{$first}) {
        $self->_print_to(\*STDERR,
            "yath2: the '$first' command has not been ported yet in this rewrite.\n",
            "See PLAN for the planned port order; until then this command is not available.\n",
        );
        return 2;
    }

    $self->_print_to(\*STDERR, "yath2: unknown command '$first'.\n\n");
    $self->_print_usage(\*STDERR);
    return 2;
}

sub _print_version {
    my $self = shift;
    my ($exit) = @_;
    my $script = $self->_display_script;
    $self->_print_to(\*STDOUT, "$script (App::Yath2 $VERSION)\n");
    return $exit;
}

sub _print_usage {
    my $self = shift;
    my ($exit_or_fh) = @_;

    my $fh = ref($exit_or_fh) ? $exit_or_fh : \*STDOUT;
    my $exit = ref($exit_or_fh) ? 0 : ($exit_or_fh // 0);

    my $script = $self->_display_script;
    my @cmds   = sort keys %COMMANDS;

    $self->_print_to(
        $fh,
        "USAGE: $script [--help | --version | COMMAND [ARGS...]]\n",
        "\n",
        "App::Yath2 (version $VERSION) is the V2 application layer for the yath\n",
        "test harness.  It is under active development; no command has been\n",
        "ported yet in this rewrite.\n",
        "\n",
        "Planned commands (all currently stubbed):\n",
        (map { "  $_\n" } @cmds),
        "\n",
        "See PLAN in the repository root for the port schedule.\n",
    );

    return $exit;
}

sub _display_script {
    my $self = shift;
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
L<App::Yath::Script::V2>. C<App::Yath2> parses the top-level C<argv>,
handles C<--help> / C<--version>, and — once commands are ported in
later stages — dispatches to them.

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

=back

=head1 METHODS

=over 4

=item $exit = $app->run

Parse L</argv>, dispatch, and return the integer exit code.

=over 4

=item * No args: print usage, exit 0.

=item * First arg C<--help>, C<-h>, or C<help>: print usage, exit 0.

=item * First arg C<--version> or C<-V>: print version, exit 0.

=item * Unknown top-level option (starts with C<->): print error +
usage to STDERR, exit 2.

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
