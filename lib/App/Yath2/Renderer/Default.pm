package App::Yath2::Renderer::Default;
use strict;
use warnings;

our $VERSION = '2.000011';

use Getopt::Yath::Term qw/term_size USE_COLOR/;
use App::Yath2::Renderer::Default::Composer();
use App::Yath2::Theme;
use Test2::Harness2::Util qw/hub_truth apply_encoding/;

use File::Spec();
use IO::Handle;
use Scalar::Util qw/blessed/;
use Storable qw/dclone/;
use Test2::Util qw/clone_io/;
use Time::HiRes qw/time/;

use parent 'App::Yath2::Renderer';
use Object::HashBase qw{
    -composer
    -last_depth
    -_buffered <_buffer
    <job_io
    +io
    <enc_io
    -_encoding
    -show_buffer
    +color
    -progress
    -tty
    -wrap
    -verbose
    -job_length
    -ecount
    -active_files
    -_active_disp
    -_file_stats
    -job_numbers
    -is_persistent
    -interactive
    +jobnum_counter
    <start_time
    <theme
    -show_job_end
    -show_job_launch
    -show_job_info
    -show_run_info
    -show_run_fields
    -show_times
};

sub TAG_WIDTH() { 8 }

sub hide_buffered() { 0 }

sub init {
    my $self = shift;

    $self->{+START_TIME} = time;

    $self->SUPER::init();

    my $io = $self->{+IO} = clone_io($self->{+IO} || \*STDOUT) or die "Cannot get a filehandle: $!";
    $io->autoflush(1);

    $self->{+TTY} //= -t $io;

    $self->{+INTERACTIVE} //= 1 if $ENV{YATH_INTERACTIVE};

    $self->{+COMPOSER} ||= App::Yath2::Renderer::Default::Composer->new;

    $self->{+SHOW_JOB_END}   //= 1;
    $self->{+VERBOSE}        //= 1;
    $self->{+JOBNUM_COUNTER} //= 1;

    $self->{+JOB_LENGTH} ||= 2;

    $self->{+COLOR} //= $self->{+TTY} ? 1 : 0;
    my $use_color = $self->{+COLOR};

    $self->{+SHOW_BUFFER} //= $use_color && USE_COLOR;

    $self->{+ECOUNT} //= 0;

    $self->{+THEME} //= App::Yath2::Theme->new(use_color => $use_color);

    my $theme = $self->{+THEME};
    my $reset = $theme->get_term_color('reset');
    my $msg   = $theme->get_term_color(status => 'message_a');
    $self->{+_ACTIVE_DISP} = ["[${msg}INITIALIZING${reset}]", ''];
    $self->{+_FILE_STATS}  = {
        passed  => 0,
        failed  => 0,
        running => 0,
        todo    => 0,
        total   => 0,
    };
}

# Return the filter chain appropriate for this renderer's verbosity level.
# quiet (-q)  → only job-summary and run-summary events
# default     → all meaningful events with the Verbose filter
sub desired_filters {
    my $self = shift;
    my $s = $self->{+SETTINGS};

    my $quiet = 0;
    if ($s) {
        if (blessed($s) && $s->can('check_group')) {
            $quiet = $s->renderer->quiet ? 1 : 0 if $s->check_group('renderer');
        }
        elsif (ref($s) eq 'HASH') {
            $quiet = $s->{quiet} ? 1 : 0;
        }
    }

    return ('App::Yath2::Filter::Quiet') if $quiet;
    return ('App::Yath2::Filter::Verbose');
}

sub render_event {
    my $self = shift;
    my ($event) = @_;

    # Deep clone — we modify facet_data to inject display hints, which
    # must not bleed through to other renderers sharing the same event.
    $event = dclone($event);

    my $f = $event->{facet_data};

    # Inject a PASSED / FAILED info line when a job completes.
    if (my $je = $f->{harness_job_end}) {
        my $pass = !$je->{fail};

        if ($self->{+SHOW_JOB_END}) {
            my $tag = $pass ? 'PASSED' : 'FAILED';
            unshift @{$f->{info}} => {
                tag       => $tag,
                debug     => $pass ? 0 : 1,
                important => 1,
                details   => $je->{rel_file} // $je->{file} // $je->{job_id} // '(unknown job)',
            };
        }
    }

    my $num = $f->{assert} && $f->{assert}{number} ? $f->{assert}{number} : undef;

    $self->write($event, $num, $f);
}

sub write {
    my ($self, $e, $num, $f) = @_;
    $f ||= blessed($e) ? $e->facet_data : $e->{facet_data};

    my $should_show = $self->update_active_disp($f);

    $self->{+ECOUNT}++;

    my $job_id = $self->_event_job_id($f);
    $self->encoding($f->{control}{encoding}, $job_id) if $f->{control} && $f->{control}{encoding};

    my $hf    = hub_truth($f);
    my $depth = $hf->{nested} || 0;

    my $also_show;
    unless ($depth) {
        my $lines = defined($job_id) ? delete $self->{+_BUFFER}->{$job_id} : undef;
        $also_show = $lines if $f->{errors} && @{$f->{errors}};
    }

    my $lines;
    if (!$self->{+VERBOSE}) {
        if ($depth) {
            $lines = [];
        }
        else {
            $lines = $self->build_quiet($f);
        }
    }
    elsif ($depth) {
        my $tree = $self->render_tree($f, '>');
        $lines = $self->build_buffered_event($f, $tree);

        if (defined $job_id) {
            push @{$self->{+_BUFFER}->{$job_id} //= []} => @$lines;
            return unless $self->{+SHOW_BUFFER} || $self->{+PROGRESS} || $also_show;
        }
    }
    else {
        my $tree = $self->render_tree($f);
        $lines = $self->build_event($f, $tree);
    }

    my ($peek) = map { $_->{peek} } grep { $_->{peek} } @{$f->{info} // []};

    $should_show ||= $also_show || ($lines && @$lines);
    unless ($should_show || $self->{+VERBOSE}) {
        if (my $last = $self->{last_rendered}) {
            return if time - $last < 0.2;
            $self->{last_rendered} = time;
        }
        else {
            $self->{last_rendered} = time;
        }
    }

    $self->{+THEME}->free_job_color($job_id) if $job_id && $f->{harness_job_end};

    # Local is expensive! Only do it if we really need to.
    local($\, $,) = (undef, '') if $\ || $,;

    my $io = $self->io($job_id);
    if (my $buffered = delete $self->{+_BUFFERED}) {
        print $io "\r";
        print $io "\e[K" unless $buffered eq 'peek';
    }

    if ($also_show) {
        print $io $_, "\n" for @$also_show;
    }

    if ($peek) {
        my $last = pop(@$lines);
        print $io $_, "\n" for @$lines;
        print $io $last;

        if ($peek eq 'peek_end') {
            print $io "\n";
        }
        else {
            $self->{+_BUFFERED} = $peek;
        }

        $io->flush();
    }
    elsif (!$self->{+VERBOSE}) {
        print $io $_, "\n" for @$lines;
        if ($self->{+TTY} && $self->{+PROGRESS}) {
            print $io $self->render_status($f);
            $self->{+_BUFFERED} = 'progress';
        }
    }
    elsif ($depth && $lines && @$lines) {
        print $io $lines->[0];
        $self->{+_BUFFERED} = 'subtest';
    }
    else {
        print $io $_, "\n" for @$lines;
    }

    delete $self->{+JOB_IO}->{$job_id} if $job_id && $f->{harness_job_end};
}

sub finish {
    my $self = shift;

    my $io = $self->{+IO};
    print $io "\r\e[K" if $self->{+_BUFFERED};

    $self->SUPER::finish(@_);

    return;
}

sub io {
    my $self = shift;
    my ($job_id) = @_;
    return $self->{+IO} unless defined $job_id;
    return $self->{+JOB_IO}->{$job_id} // $self->{+IO};
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc, $job_id) = @_;
        if (defined $job_id) {
            my $io;

            unless ($io = $self->{+ENC_IO}->{$enc}) {
                $io = $self->{+ENC_IO}->{$enc} = clone_io($self->{+IO} || \*STDOUT) or die "Cannot get a filehandle: $!";
                $io->autoflush(1);
                apply_encoding($io, $enc);
            }

            $self->{+JOB_IO}->{$job_id} = $io;
        }
        else {
            apply_encoding($self->{+IO}, $enc);
        }
        $self->{+_ENCODING} = $enc;
    }

    return $self->{+_ENCODING};
}

sub step {
    my $self = shift;

    return unless $self->update_active_disp;

    my $io = $self->io(0);
    if ($self->{+_BUFFERED}) {
        print $io "\r\e[K";
        $self->{+_BUFFERED} = 0;
    }

    if ($self->{+TTY} && $self->{+PROGRESS}) {
        print $io $self->render_status();
        $self->{+_BUFFERED} = 1;
    }
}

sub update_active_disp {
    my $self = shift;
    my ($f) = @_;
    my $should_show = 0;

    my $stats = $self->{+_FILE_STATS};

    my $out = 0;
    $out = $self->update_spinner($stats) unless $stats->{started};

    return $out unless $f;

    if ($f->{harness_job_queued}) {
        $stats->{todo}++;
        $stats->{total}++;
        $should_show = 1;
    }

    if ($f->{harness_job_start}) {
        $stats->{started}  //= 1;
        $stats->{running}++;
        $stats->{todo}-- if $stats->{todo} > 0;
        $should_show = 1;
    }

    if (my $je = $f->{harness_job_end}) {
        $should_show      = 1;
        $stats->{started} //= 1;
        $stats->{running}-- if $stats->{running} > 0;
        if (!$je->{fail}) { $stats->{passed}++ }
        else              { $stats->{failed}++ }
    }

    return $out unless $should_show;

    my $theme    = $self->{+THEME};
    my $statline = join '|' => (
        $self->_highlight($stats->{passed},  'P', $theme->get_term_color(state => 'passed')),
        $self->_highlight($stats->{failed},  'F', $theme->get_term_color(state => 'failed')),
        $self->_highlight($stats->{running}, 'R', $theme->get_term_color(state => 'running')),
        $self->_highlight($stats->{todo},    'T', $theme->get_term_color(state => 'todo')),
    );

    $statline = "[$statline]";

    $self->{+_ACTIVE_DISP} = [$statline, ''];

    return 1;
}

sub update_spinner {
    my $self = shift;
    my ($stats) = @_;

    my $theme = $self->{+THEME};

    $stats->{spinner}      //= '|';
    $stats->{spinner_time} //= time - 1;
    $stats->{blink_time}   //= time - 1;
    $stats->{blink}        //= '';

    my $msg     = $theme->get_term_color(status => 'message_a');
    my $cmd     = $theme->get_term_color(status => 'command');
    my $spin    = $theme->get_term_color(status => 'spinner');
    my $border  = $theme->get_term_color(status => 'border');
    my $sub_msg = $theme->get_term_color(status => 'sub_message');
    my $reset   = $theme->get_term_color('reset');

    if (time - $stats->{spinner_time} > 0.1) {
        $stats->{spinner_time} = time;
        my $start = substr($stats->{spinner}, 0, 1);
        $stats->{spinner} = '\\' if $start eq '-';
        $stats->{spinner} = '-'  if $start eq '/';
        $stats->{spinner} = '/'  if $start eq '|';
        $stats->{spinner} = '|'  if $start eq '\\';
    }
    elsif (time - $stats->{blink_time} > 0.5) {
        $stats->{blink_time} = time;
        $msg = $theme->get_term_color(status => 'message_b') if $stats->{blink};
    }
    else {
        return 0;
    }

    $self->{+_ACTIVE_DISP} = [
        join(
            '' => (
                $border => "[ ",              $reset,
                $spin   => $stats->{spinner}, $reset,
                ''      => " ",
                $self->{+IS_PERSISTENT}
                ? (
                    $msg     => "Waiting for busy runner", $reset,
                    ''       => " ",
                    $sub_msg => "(see ",       $reset,
                    $cmd     => "yath status", $reset,
                    $sub_msg => ")",           $reset,
                    )
                : ($msg => "INITIALIZING", $reset),
                ''      => " ",
                $spin   => $stats->{spinner}, $reset,
                $border => " ]",              $reset,
            )
        ),
        '',
    ];

    return 1;
}

sub _highlight {
    my $self = shift;
    my ($val, $label, $color) = @_;

    return "${label}:${val}" unless $val && $self->{+COLOR};
    return sprintf('%s%s:%d%s', $color, $label, $val, $self->reset);
}

sub colorstrip {
    my $self = shift;
    my ($str) = @_;

    return $str unless USE_COLOR;
    require Term::ANSIColor;
    return Term::ANSIColor::colorstrip($str);
}

sub render_status {
    my $self = shift;

    my $theme = $self->theme;

    my $reset   = $self->reset;
    my $message = $theme->get_term_color(status => 'default') || '';

    my $str = "$self->{+_ACTIVE_DISP}->[0] Events: $self->{+ECOUNT} ${message}$self->{+_ACTIVE_DISP}->[1]${reset}";

    my $max = term_size() || 80;

    if (length($str) > $max) {
        my $nocolor = $self->colorstrip($str);
        $str = substr($nocolor, 0, $max - 8) . " ...)$reset" if length($nocolor) > $max;
        $str =~ s/\(/$message(/;
        $str =~ s/^\[[^\]]+\]/$self->{+_ACTIVE_DISP}->[0]/;
    }

    return $str;
}

sub build_buffered_event {
    my $self = shift;
    my ($f, $tree) = @_;

    my $comp = $self->{+COMPOSER}->render_one_line($f) or return;

    return unless @$comp;
    return [$self->build_line($tree, @$comp)];
}

sub build_event {
    my $self = shift;
    my ($f, $tree) = @_;

    my $comps = $self->{+COMPOSER}->render_verbose($f);

    my (@parent, @times);

    if ($f->{parent}) {
        @parent = $self->render_parent($f, $tree);

        if (@$comps && $comps->[-1]->[0] eq 'times') {
            my $times = pop(@$comps);
            @times = $self->build_line($tree, @$times);
        }
    }

    my @out;

    for my $comp (@$comps) {
        my $ctree = $tree;
        substr($ctree, -2, 2, '+~') if $comp->[0] eq 'assert' && $f->{parent};
        push @out => $self->build_line($ctree, @$comp);
    }

    push @out => (@parent, @times);

    return \@out;
}

sub build_quiet {
    my $self = shift;
    my ($f, $tree) = @_;

    my @out;

    my $comps = $self->{+COMPOSER}->render_brief($f);
    for my $comp (@$comps) {
        my $ctree = $tree ||= $self->render_tree($f);
        substr($ctree, -2, 2, '+~') if $comp->[0] eq 'assert' && $f->{parent};
        push @out => $self->build_line($ctree, @$comp);
    }

    if ($f->{parent} && !$f->{amnesty}) {
        push @out => $self->render_parent($f, $tree ||= $self->render_tree($f), quiet => 1);
    }

    return \@out;
}

sub reset {
    my $self = shift;
    return $self->{+THEME}->get_term_color('reset');
}

sub _event_job_id {
    my ($self, $f) = @_;
    return $f->{harness}{job_id} if $f->{harness} && defined $f->{harness}{job_id};
    for my $k (qw/harness_job_end harness_job_start harness_job_queued harness_job_exit/) {
        return $f->{$k}{job_id}
            if ref($f->{$k}) eq 'HASH' && defined $f->{$k}{job_id};
    }
    return undef;
}

sub render_tree {
    my $self = shift;
    my ($f, $char) = @_;
    $char ||= '|';

    my $job = '';
    my $jid = $self->_event_job_id($f);
    if (defined $jid || $f->{harness}) {
        my $id     = $jid // 0;
        my $number = $id ? $self->{+JOB_NUMBERS}->{$id} //= $self->{+JOBNUM_COUNTER}++ : $id;

        my $theme = $self->{+THEME};
        my $color = $theme->get_term_color(job => $id);
        my $reset = $theme->get_term_color('reset');

        my $len = length($number) // 0;
        if (!$self->{+JOB_LENGTH} || $len > $self->{+JOB_LENGTH}) {
            $self->{+JOB_LENGTH} = $len;
        }
        else {
            $len = $self->{+JOB_LENGTH};
        }

        # Match 1.0's spacing: "job  1" (number right-aligned within the
        # max number width) or "RUNNER" left-aligned to the same width as
        # "job <number>".
        my $label_width = 4 + $len;    # "job " + max number width
        $label_width = 6 if $label_width < 6;
        if ($id) {
            $job = sprintf("%sjob %${len}s%s ", $color, $number, $reset || '');
        }
        else {
            $job = sprintf("%s%-${label_width}s%s ", $color, 'RUNNER', $reset || '');
        }
    }

    my $hf    = hub_truth($f);
    my $depth = $hf->{nested} || 0;

    my @pipes = (' ', map $char, 1 .. $depth);
    return join(' ' => $job, @pipes) . " ";
}

sub build_line {
    my $self = shift;
    my ($tree, $facet, $tag, $text) = @_;

    $tree ||= '';
    $tag  ||= '';
    $text ||= '';
    chomp($text);

    $tree = "$tree";

    substr($tree, -2, 1, '+') if $facet eq 'assert';

    $tag = substr($tag, 0 - TAG_WIDTH, TAG_WIDTH) if length($tag) > TAG_WIDTH;

    my $use_color = $self->{+COLOR};
    my $max       = $self->{+TTY} && $self->{+WRAP} ? (term_size() || 80) : undef;
    my $theme     = $self->{+THEME};
    my $reset     = $self->reset;
    my $tcolor    = $theme->get_term_color(tag => $tag) || $theme->get_term_color(facet => $facet) || '';

    my ($ps, $pe) = @{$theme->get_borders($facet)};

    $tag = uc($tag);
    my $length = length($tag);
    if ($length > TAG_WIDTH) {
        $tag = substr($tag, 0, TAG_WIDTH);
    }
    elsif ($length < TAG_WIDTH) {
        my $pad  = (TAG_WIDTH - $length) / 2;
        my $padl = $pad + (TAG_WIDTH - $length) % 2;
        $tag = (' ' x $padl) . $tag . (' ' x $pad);
    }

    my $start;
    if ($use_color) {
        my $border = $theme->get_term_color(base => 'tag_border') || '';
        $start = "${reset}${border}${ps}${reset}${tcolor}${tag}${reset}${border}${pe}${reset}";
    }
    else {
        $start = "${ps}${tag}${pe}";
    }

    $start .= "  ";

    if ($tree) {
        if ($use_color) {
            my $trcolor = $theme->get_term_color(base => 'tree') || '';
            $start .= $trcolor . $tree . $reset;
        }
        else {
            $start .= $tree;
        }
    }

    my @lines = split /[\r\n]/, $text;
    @lines = ($text) unless @lines;

    my @out;
    for my $line (@lines) {
        if (@lines > 1 && $max && length("$ps$tag$pe $tree$line") > $max) {
            @out = ();
            last;
        }

        if ($use_color) {
            push @out => "${start}${tcolor}${line}$reset";
        }
        else {
            push @out => "${start}${line}";
        }
    }

    unless (@out) {
        if ($use_color) {
            my $blob = $theme->get_term_color(base => 'blob') || '';
            @out = (
                "$start${blob}----- START -----$reset",
                "${tcolor}${text}${reset}",
                "$start${blob}------ END ------$reset",
            );
        }
        else {
            @out = (
                "$start----- START -----",
                $text,
                "$start------ END ------",
            );
        }
    }

    return @out;
}

sub render_parent {
    my $self = shift;
    my ($f, $tree, %params) = @_;

    my $meth = $params{quiet} ? 'build_quiet' : 'build_event';

    my @out;
    my $ph = $f->{harness} || {};
    for my $sf (@{$f->{parent}->{children}}) {
        my $ch = $sf->{harness} //= {};
        $ch->{job_id} //= $ph->{job_id} if defined $ph->{job_id};
        $ch->{run_id} //= $ph->{run_id} if defined $ph->{run_id};
        my $stree = $self->render_tree($sf);
        push @out => @{$self->$meth($sf, $stree)};
    }

    return unless @out;

    push @out => ($self->build_line("$tree^", 'parent', '', ''));

    return @out;
}

sub DESTROY {
    my $self = shift;

    my $io = $self->{+IO} or return;

    # Local is expensive! Only do it if we really need to.
    local($\, $,) = (undef, '') if $\ || $,;

    print $io Getopt::Yath::Term::color('reset') if USE_COLOR;

    print $io "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Default - Default human-readable renderer for L<App::Yath2>.

=head1 DESCRIPTION

This renderer is the primary renderer used for final result rendering when you
use L<App::Yath2>. It formats the event stream from the
L<App::Yath2::OutputManager> into coloured, tree-structured terminal output.

Filtering decisions (quiet vs. verbose) are the responsibility of the filter
chain declared by C<desired_filters>. This renderer only handles formatting.

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
