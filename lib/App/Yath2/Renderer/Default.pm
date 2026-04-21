package App::Yath2::Renderer::Default;
use strict;
use warnings;

our $VERSION = '2.000011';

use Scalar::Util qw/blessed/;

use App::Yath2::Renderer::Theme::Composer();

use Object::HashBase qw{
    <io
    <composer
    <tag_width
    +seen_assertions
    +seen_failures
    +start_stamps
    +end_stamps
    +job_file_map
};

use Role::Tiny::With;
with 'App::Yath2::Role::Renderer';

# Minimal live renderer. Receives events from the artifact-reading
# layer and writes a human-readable line per event to $self->{+IO}.
# Not a bug-for-bug port of old/lib/App/Yath2/Renderer/Default.pm --
# the old renderer read files directly and maintained a terminal
# TUI. Stage 12's contract per IPC_AND_LOGGERS §13 is to consume an
# event stream only; TUI machinery can land later as a pure-output
# refinement without changing the role's inputs.
#
# Output shape:
#   ( <tag_column> )  <job-prefix>  <text>
# where tag_column is left-padded to TAG_WIDTH. A "job-prefix" is
# the short basename of the test file (when the event carries
# harness.job_id/test_file) so concurrent jobs are distinguishable.

sub init {
    my $self = shift;

    $self->{+IO} //= \*STDOUT;
    unless (ref($self->{+IO})) {
        my $path = $self->{+IO};
        open(my $fh, '>', $path)
            or die "Cannot open '$path' for writing: $!";
        $self->{+IO} = $fh;
    }
    $self->{+IO}->autoflush(1) if $self->{+IO}->can('autoflush');

    $self->{+COMPOSER} //= App::Yath2::Renderer::Theme::Composer->new;
    $self->{+TAG_WIDTH}       //= 8;
    $self->{+SEEN_ASSERTIONS} //= 0;
    $self->{+SEEN_FAILURES}   //= 0;
    $self->{+START_STAMPS}    //= {};
    $self->{+END_STAMPS}      //= {};
    $self->{+JOB_FILE_MAP}    //= {};

    return;
}

sub start_of_run {
    my ($self, %info) = @_;
    my $rid = $info{run_id} // '(unknown)';
    print { $self->{+IO} } $self->_format_line('RUN', $rid, "starting run");
    return;
}

sub event_in {
    my ($self, $event) = @_;

    my $f = ref($event) eq 'HASH' ? $event->{facet_data} // {} : {};
    my $h = $f->{harness};

    # Lifecycle events from the harness's own collector carry the
    # kind slot under the harness facet (see IPC_AND_LOGGERS §6.3).
    # We surface the common ones inline; everything else gets the
    # composer's brief rendering so a verbose event still produces
    # at least one line.
    return $self->_render_harness_event($event, $f, $h)
        if ref($h) eq 'HASH' && _is_harness_lifecycle($h);

    my $triples = $self->{+COMPOSER}->render_brief($f);
    $triples //= [];

    for my $triple (@$triples) {
        my ($facet, $tag, $text) = @$triple;
        $self->{+SEEN_ASSERTIONS}++ if $facet eq 'assert';
        $self->{+SEEN_FAILURES}++   if $facet eq 'assert' && $tag eq 'FAIL';
        my $job_label = $self->_job_label($h);
        print { $self->{+IO} } $self->_format_line($tag, $job_label, $text);
    }

    return;
}

sub end_of_run {
    my ($self, %summary) = @_;

    my $rid   = $summary{run_id}     // '(unknown)';
    my $pass  = $summary{pass_count} // 0;
    my $fail  = $summary{fail_count} // 0;
    my $label = $fail ? 'FAILED' : 'PASSED';

    print { $self->{+IO} } $self->_format_line(
        $label, $rid, "run complete: $pass passed, $fail failed",
    );

    return;
}

sub shutdown { }

sub _is_harness_lifecycle {
    my ($h) = @_;
    return 0 unless ref($h) eq 'HASH';
    for my $k (qw/run_started run_ended run_complete job_started job_completed job_loggers test_job_started test_job_completed/) {
        return 1 if exists $h->{$k};
    }
    return 0;
}

# Handle well-known harness lifecycle slots. Emit a short line per
# recognised kind; fall back to the generic composer path for
# unrecognised ones (via the caller's loop).
sub _render_harness_event {
    my ($self, $event, $f, $h) = @_;

    if (my $s = $h->{job_started} || $h->{test_job_started}) {
        my $job_id = $s->{job_id} // $h->{job_id};
        $self->{+START_STAMPS}->{$job_id} = $event->{stamp}
            if defined $job_id && defined $event->{stamp};
        my $label = $self->_job_label($h);
        print { $self->{+IO} } $self->_format_line('LAUNCH', $label, 'test started');
        return;
    }

    if (my $c = $h->{job_completed} || $h->{test_job_completed}) {
        my $job_id = $c->{job_id} // $h->{job_id};
        $self->{+END_STAMPS}->{$job_id} = $event->{stamp}
            if defined $job_id && defined $event->{stamp};
        my $pass = exists $c->{pass} ? $c->{pass} : 1;
        my $tag  = $pass ? 'PASSED' : 'FAILED';
        my $label = $self->_job_label($h);
        print { $self->{+IO} } $self->_format_line($tag, $label, 'test complete');
        return;
    }

    if (my $lg = $h->{job_loggers}) {
        # Track which log files each job produced so -v replays (in the
        # Formatter renderer) know where to look. Default renderer just
        # records; it does not print unless verbose mode is on.
        my $job_id = $lg->{job_id} // $h->{job_id};
        if (defined $job_id) {
            my $files = _extract_log_files($h->{loggers} // {});
            $self->{+JOB_FILE_MAP}->{$job_id} //= [];
            push @{$self->{+JOB_FILE_MAP}->{$job_id}} => @$files if @$files;
        }
        return;
    }

    if ($h->{run_started}) {
        print { $self->{+IO} } $self->_format_line('RUN', $h->{run_id} // '?', 'run started');
        return;
    }

    if ($h->{run_complete} || $h->{run_ended}) {
        # Don't duplicate: end_of_run is the summary channel. We can
        # still log that the run finished on the wire.
        my $rc = $h->{run_complete} // $h->{run_ended};
        print { $self->{+IO} } $self->_format_line('RUN', $rc->{run_id} // $h->{run_id} // '?', 'run ended');
        return;
    }

    return;
}

sub _extract_log_files {
    my ($loggers) = @_;
    my @files;
    for my $class (sort keys %$loggers) {
        for my $inst (@{$loggers->{$class} // []}) {
            push @files => $inst->{output_file}
                if ref($inst) eq 'HASH' && defined $inst->{output_file};
        }
    }
    return \@files;
}

sub _job_label {
    my ($self, $h) = @_;
    return '-' unless ref($h) eq 'HASH';
    my $label = $h->{job_label}
        // $h->{file}
        // $h->{test_file}
        // $h->{job_id}
        // '-';
    # Trim path to basename for readability.
    $label =~ s{^.*/}{};
    return $label;
}

sub _format_line {
    my ($self, $tag, $label, $text) = @_;
    my $w   = $self->{+TAG_WIDTH};
    my $tg  = sprintf('%-*s', $w, $tag);
    my $txt = defined $text ? $text : '';
    $txt =~ s/\s+\z//;
    return "[$tg] $label: $txt\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Default - Minimal live event renderer.

=head1 DESCRIPTION

Consumes the event stream produced by the command-side
artifact-reading layer (C<App::Yath2::ArtifactReader>) and prints a
human-readable line per event to a filehandle.

This is a minimal, role-conforming implementation of the Stage 12
renderer contract; it is not a bug-for-bug port of the old yath
live TUI. The old renderer read files directly; the new one is
strictly a passive consumer, per C<IPC_AND_LOGGERS §13>.

=head1 ATTRIBUTES

=over 4

=item io

Filehandle (or path string) the renderer writes to. Defaults to
C<STDOUT>. A path string is opened in write mode and the renderer
takes ownership of the resulting filehandle.

=item composer

L<App::Yath2::Renderer::Theme::Composer> instance used to turn
facet-data into output triples. Defaults to a fresh composer.

=item tag_width

Width of the tag column. Defaults to 8.

=back

=head1 HOOKS

This class consumes L<App::Yath2::Role::Renderer> and implements
all four hooks. C<event_in> is where the work happens; lifecycle
hooks print one-line headers / summaries bracketing the stream.

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

See L<https://dev.perl.org/licenses/>

=cut
