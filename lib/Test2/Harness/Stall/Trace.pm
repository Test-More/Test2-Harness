package Test2::Harness::Stall::Trace;
use strict;
use warnings;

our $VERSION = '1.000180';

use File::Spec();

use Importer Importer => 'import';

our @EXPORT_OK = qw/install_trace_handler stack_trace/;

# Deliberately small. Everything a watcher can see from outside -- /proc, open
# files, the run state -- is collected by whoever sends the signal, because a
# process wedged in an uninterruptible syscall never runs this at all. The Perl
# call stack is the one thing only the process itself can produce, so it is the
# only thing gathered here. Nothing in this file may walk harness objects or
# take a lock; the process is already believed stuck.
sub stack_trace {
    my @frames;

    my $i = 0;
    while (my @caller = caller($i++)) {
        my ($pkg, $file, $line, $sub) = @caller;

        # Plain caller(), never Carp::longmess: longmess formats each frame's
        # arguments, and those hold the resource objects and task hashrefs
        # belonging to the code we suspect of being stuck.
        push @frames => {
            package => $pkg,
            file    => $file,
            line    => $line,
            sub     => $sub,
        };

        last if $i > 200;
    }

    return \@frames;
}

sub _render {
    my ($frames) = @_;

    my $out = "$$ $0 stack trace:\n";
    my $i   = 0;
    for my $frame (@$frames) {
        $out .= sprintf("  [%d] %s at %s line %s\n", $i++, $frame->{sub}, $frame->{file}, $frame->{line});
    }

    return $out;
}

sub _write_trace {
    my ($dir, $round) = @_;

    my $frames = stack_trace();
    my $text   = _render($frames);

    # Its own STDERR first, so the trace survives even if whoever asked for it
    # dies before collecting the files. For the runner and its children that is
    # error.log, which the collector already forwards.
    print STDERR "\n$text";

    return unless $dir && -d $dir;

    my $file = File::Spec->catfile($dir, "stack-$$-$round.txt");
    open(my $fh, '>', $file) or return;
    print $fh $text;

    return;
}

# Installed in every harness process, never in a test job. A job process sheds
# this handler when the runner's Scope::Guard restores the original %SIG, so
# SIGUSR1 there takes its default action and kills the test. Whoever signals
# must use a whitelist of known harness pids and must never signal a process
# group.
sub install_trace_handler {
    my ($dir) = @_;

    my $round = 0;

    $SIG{USR1} = sub {
        local ($!, $@, $_);
        $round++;
        eval { _write_trace($dir, $round); 1 };
    };

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Stall::Trace - Report a process's own Perl call stack on
demand.

=head1 DESCRIPTION

Deliberately small. Everything a watcher can see from outside a stuck process
-- C</proc> state, wait channels, open files, the run state -- is collected by
whoever sends the signal, because a process wedged in an uninterruptible
syscall never runs a handler at all, and that is the case most in need of
description. The Perl call stack is the one thing only the process itself can
produce, so it is the only thing gathered here.

Nothing in this module may walk harness objects or take a lock; by the time it
runs, the process is already believed stuck. It uses a plain C<caller> loop
rather than C<Carp::longmess>, which formats each frame's arguments -- and
those hold the resource objects and task hashrefs belonging to the code under
suspicion.

=head2 NEVER SIGNAL A TEST JOB

The handler is installed in harness processes only: the runner, the scheduler,
the stages, the collector and the auditor. A test job process sheds it when the
runner's C<Scope::Guard> restores the original C<%SIG>, so C<SIGUSR1> there
takes its default action and B<terminates the test>.

Whoever sends the signal must therefore use a whitelist of known harness pids,
and must never signal a process group.

=head1 SYNOPSIS

    use Test2::Harness::Stall::Trace qw/install_trace_handler/;

    install_trace_handler(File::Spec->catdir($workdir, 'stall'));

=head1 EXPORTS

=over 4

=item install_trace_handler($dir)

Installs the C<SIGUSR1> handler. Each signal writes the frames to the process's
own STDERR, and to C<$dir/stack-$$-N.txt> where N counts up per process.

Install it after any snapshot of C<%SIG> the process intends to restore, so a
forked test job sheds it.

=item $arrayref = stack_trace()

The current call stack as a list of hashrefs with C<package>, C<file>, C<line>
and C<sub>. Frame arguments are never touched.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
