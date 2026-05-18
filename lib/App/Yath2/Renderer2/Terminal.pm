package App::Yath2::Renderer2::Terminal;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use IO::Handle ();

use parent 'App::Yath2::Renderer2::Base';

# Flat-namespaced option group owned by this renderer. The `terminal`
# prefix is asserted as exclusively owned by this class via
# App::Yath2::Renderer2::Registry. terminal-auto is a selector that
# resolves to this same class and therefore shares the prefix without
# triggering a conflict (assert_prefix is idempotent for the same
# class).
use Getopt::Yath;
option_group {group => 'terminal', prefix => 'terminal', category => 'Terminal renderer options'} => sub {
    option verbose => (
        type        => 'Count',
        description => 'Verbosity level for the terminal renderer (repeatable). 0 (default) = QVF: passing jobs print a single PASS line, failing jobs dump events. >=1 also prints a per-job start line.',
        initialize  => 0,
    );

    option out => (
        type        => 'Scalar',
        description => 'Write terminal renderer output to PATH instead of STDOUT. Use "-" for STDOUT (the default).',
        long_examples  => [' PATH'],
        short_examples => [' PATH'],
    );

    option formatter => (
        type        => 'Scalar',
        description => 'Override the formatter selection. Accepts a short name (txt, tty) or "+Fully::Qualified::Class". Defaults to TerminalAuto which picks txt/tty based on whether the output is a TTY.',
        long_examples  => [' txt', ' tty', ' +My::Formatter'],
        short_examples => [' txt', ' tty', ' +My::Formatter'],
    );
};

# One-liner accessors: these are the only per-call internal reads.
sub _verbose   { $_[0]->settings->{verbose}   // 0 }
sub _formatter { $_[0]->settings->{formatter} // croak "settings.formatter is required" }
sub _out       { $_[0]->out_fh                // croak "out_fh is required" }

sub start {
    my $self = shift;
    my $fh   = $self->_out;
    $fh->autoflush(1) if $fh->can('autoflush');
    return;
}

# handle_run_opened is a no-op in v1 (QVF). A brief heading could be
# added here in a follow-up that implements the --header option.

sub handle_job_opened {
    my ($self, $job_p) = @_;

    return unless $self->_verbose >= 1;

    my $fh = $self->_out;
    printf {$fh} "HARNESS: job %s try %s started\n", $job_p->id, $job_p->try // 0;
    return;
}

sub handle_job_sealed {
    my ($self, $job_p) = @_;
    my $fh   = $self->_out;
    my $pass = $job_p->pass;

    if ($pass) {
        printf {$fh} "PASS: job %s try %s\n", $job_p->id, $job_p->try // 0;
        return;
    }

    # Failure: always dump events through the formatter regardless of
    # verbosity level. In verbose mode (>=1) the events were already
    # streamed live; we still print a FAIL summary line here and then
    # replay the events so the failure context is visible even when the
    # live output scrolled past.
    printf {$fh} "FAIL: job %s try %s\n", $job_p->id, $job_p->try // 0;

    my $reader = $job_p->artifact('events');
    return unless $reader;

    my $formatter = $self->_formatter;
    while (defined(my $item = $reader->readline)) {
        my $text = $formatter->convert_item($item);
        print {$fh} $text if length $text;
    }

    return;
}

sub handle_run_sealed {
    my ($self, $run_p) = @_;
    my $fh = $self->_out;
    printf {$fh} "HARNESS: run %s %s (exit=%s)\n",
        $run_p->id,
        ($run_p->pass ? 'PASSED' : 'FAILED'),
        ($run_p->exit // '?');
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer2::Terminal - Terminal renderer for Test2 harness output.

=head1 SYNOPSIS

    use App::Yath2::Renderer2::Terminal;
    use App::Yath2::Formatter::Txt;
    use App::Yath2::Renderer2::Loop;

    my $renderer = App::Yath2::Renderer2::Terminal->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        settings    => {
            verbose   => 0,
            formatter => App::Yath2::Formatter::Txt->new,
        },
    );

    App::Yath2::Renderer2::Loop::run($renderer);

=head1 DESCRIPTION

C<App::Yath2::Renderer2::Terminal> is the first concrete renderer built on the
C<App::Yath2::Renderer2::Base> foundation. It writes human-readable output to
C<out_fh> (typically C<STDOUT>) using a caller-supplied formatter.

=head2 Verbosity policy (QVF mode, verbose=0)

This version implements QVF (Quiet-on-Verbosity-Zero) behaviour:

=over 4

=item Passing jobs

Emit a single C<PASS: job N try N> summary line when the job is sealed.
No per-event output is produced.

=item Failing jobs

Emit a C<FAIL: job N try N> header line followed by every event from the
job's C<events> artifact fed through the formatter. This gives the full
failure context without requiring the operator to run C<yath failed>.

=item Run summary

Emit C<HARNESS: run N PASSED|FAILED (exit=N)> after all jobs have been
processed.

=back

=head2 Verbose mode (verbose >= 1)

When C<< settings->{verbose} >= 1 >>, a C<HARNESS: job N try N started>
line is printed when a job is first observed (opened). The failure event
dump on seal is still performed so the context is available even when live
output has scrolled away.

Live event streaming (tailing the partial C<events.jsonl> while a job
is running) is not yet implemented in this version. It will be added in
a follow-up.

=head1 SETTINGS

The following keys are recognised in the C<settings> hashref:

=over 4

=item C<verbose>

Integer. Controls output verbosity. C<0> (the default) enables QVF mode.
C<1> or higher additionally emits job-start lines.

=item C<formatter>

Required. An C<App::Yath2::Formatter> instance (typically
C<App::Yath2::Formatter::Txt> or C<App::Yath2::Formatter::Tty>) used to
convert event hashrefs to printable text.

=back

=head1 ATTRIBUTES

Inherits all attributes from L<App::Yath2::Renderer2::Base>.

=over 4

=item C<out_fh>

Required. Filehandle that all output is written to. C<start> calls
C<< $fh->autoflush(1) >> when the filehandle supports that method.

=back

=head1 METHODS

=over 4

=item $r->start

Enable autoflush on C<out_fh> (when supported). Called once by the
render loop before the poll cycle begins.

=item $r->handle_job_opened($job_p)

At C<verbose >= 1>: print a C<HARNESS: job N try N started> line.
At C<verbose == 0>: no-op.

=item $r->handle_job_sealed($job_p)

Emit output for a completed job:

=over 4

=item *

On pass: one line C<PASS: job N try N>.

=item *

On fail: a C<FAIL: job N try N> header followed by every event from the
job's events artifact rendered through the formatter.

=back

=item $r->handle_run_sealed($run_p)

Emit a run summary line: C<HARNESS: run N PASSED|FAILED (exit=N)>.

=back

=head1 SEE ALSO

L<App::Yath2::Renderer2::Base>, L<App::Yath2::Renderer2::Loop>,
L<App::Yath2::Formatter::Txt>, L<App::Yath2::Formatter::Tty>.

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
