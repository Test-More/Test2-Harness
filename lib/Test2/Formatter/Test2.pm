package Test2::Formatter::Test2;
use strict;
use warnings;

our $VERSION = '1.000155';

use Test2::Util::Term qw/term_size/;
use Test2::Harness::Util qw/hub_truth apply_encoding/;
use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;
use Test2::Util qw/IS_WIN32 clone_io/;
use Time::HiRes qw/time/;
use IO::Handle;

use File::Spec();
use Test2::Formatter::Test2::Composer;

use parent 'Test2::Formatter';

sub import {
    my $class = shift;
    return if $ENV{HARNESS_ACTIVE};
    $class->SUPER::import;
}

use Test2::Util::HashBase qw{
    -composer
    -last_depth
    -_buffered
    <job_io
    +io
    <enc_io
    -_encoding
    -show_buffer
    -color
    -progress
    -tty
    -no_wrap
    -verbose
    -job_length
    -ecount
    -job_colors
    -active_files
    -_active_disp
    -_file_stats
    -job_names
    -is_persistent
    -interactive
};

sub TAG_WIDTH() { 8 }

sub hide_buffered() { 0 }

sub DEFAULT_TAG_COLOR() {
    return (
        'DEBUG'    => Term::ANSIColor::color('red'),
        'DIAG'     => Term::ANSIColor::color('yellow'),
        'ERROR'    => Term::ANSIColor::color('red'),
        'FATAL'    => Term::ANSIColor::color('bold red'),
        'FAIL'     => Term::ANSIColor::color('red'),
        'HALT'     => Term::ANSIColor::color('bold red'),
        'PASS'     => Term::ANSIColor::color('green'),
        '! PASS !' => Term::ANSIColor::color('cyan'),
        'TODO'     => Term::ANSIColor::color('cyan'),
        'NO  PLAN' => Term::ANSIColor::color('yellow'),
        'SKIP'     => Term::ANSIColor::color('bold cyan'),
        'SKIP ALL' => Term::ANSIColor::color('bold white on_blue'),
        'STDERR'   => Term::ANSIColor::color('yellow'),
        'RUN INFO' => Term::ANSIColor::color('bold bright_blue'),
        'JOB INFO' => Term::ANSIColor::color('bold bright_blue'),
        'LAUNCH'   => Term::ANSIColor::color('bold bright_white'),
        'RETRY'    => Term::ANSIColor::color('bold bright_white'),
        'PASSED'   => Term::ANSIColor::color('bold bright_green'),
        'TO RETRY' => Term::ANSIColor::color('bold bright_yellow'),
        'FAILED'   => Term::ANSIColor::color('bold bright_red'),
        'REASON'   => Term::ANSIColor::color('magenta'),
        'TIMEOUT'  => Term::ANSIColor::color('magenta'),
        'TIME'     => Term::ANSIColor::color('blue'),
        'MEMORY'   => Term::ANSIColor::color('blue'),
    );
}

sub DEFAULT_FACET_COLOR() {
    return (
        time    => Term::ANSIColor::color('blue'),
        memory  => Term::ANSIColor::color('blue'),
        about   => Term::ANSIColor::color('magenta'),
        amnesty => Term::ANSIColor::color('cyan'),
        assert  => Term::ANSIColor::color('bold bright_white'),
        control => Term::ANSIColor::color('bold red'),
        error   => Term::ANSIColor::color('yellow'),
        info    => Term::ANSIColor::color('yellow'),
        meta    => Term::ANSIColor::color('magenta'),
        parent  => Term::ANSIColor::color('magenta'),
        trace   => Term::ANSIColor::color('bold red'),
    );
}

# These colors all look decent enough to use, ordered to avoid putting similar ones together
use constant DEFAULT_JOB_COLOR_NAMES => (
        'bold green on_blue',
        'bold blue on_white',
        'bold black on_cyan',
        'bold green on_bright_black',
        'bold dark blue on_white',
        'bold black on_green',
        'bold cyan on_blue',
        'bold black on_white',
        'bold white on_cyan',
        'bold cyan on_bright_black',
        'bold white on_green',
        'bold bright_black on_white',
        'bold white on_blue',
        'bold bright_cyan on_green',
        'bold blue on_cyan',
        'bold white on_bright_black',
        'bold bright_black on_green',
        'bold bright_green on_blue',
        'bold bright_blue on_white',
        'bold bright_white on_bright_black',
        'bold yellow on_blue',
        'bold bright_black on_cyan',
        'bold bright_green on_bright_black',
        'bold blue on_green',
        'bold bright_cyan on_blue',
        'bold bright_blue on_cyan',
        'bold dark bright_white on_bright_black',
        'bold bright_blue on_green',
        'bold dark bright_blue on_white',
        'bold bright_white on_blue',
        'bold bright_cyan on_bright_black',
        'bold bright_white on_cyan',
        'bold bright_white on_green',
        'bold bright_yellow on_blue',
        #'bold magenta on_white',
        #'bold dark magenta on_white',
        #'bold dark cyan on_white',
        'bold dark bright_cyan on_bright_black',
        #'bold dark bright_green on_black',
        #'bold dark bright_yellow on_black',
);

sub DEFAULT_JOB_COLOR() {
    return map { Term::ANSIColor::color($_) } DEFAULT_JOB_COLOR_NAMES;
}

sub DEFAULT_COLOR() {
    return (
        reset      => Term::ANSIColor::color('reset'),
        blob       => Term::ANSIColor::color('bold bright_black on_white'),
        tree       => Term::ANSIColor::color('bold bright_white'),
        tag_border => Term::ANSIColor::color('bold bright_white'),
    );
}

my %FACET_TAG_BORDERS = (
    'default' => ['[', ']'],
    'amnesty' => ['{', '}'],
    'info'    => ['(', ')'],
    'error'   => ['<', '>'],
    'parent'  => [' ', ' '],
);

sub init {
    my $self = shift;

    $self->{+COMPOSER} ||= Test2::Formatter::Test2::Composer->new;

    $self->{+VERBOSE} = 1 unless defined $self->{+VERBOSE};

    $self->{+JOB_LENGTH} ||= 2;

    my $io = $self->{+IO} = clone_io($self->{+IO} || \*STDOUT) or die "Cannot get a filehandle: $!";
    $io->autoflush(1);

    $self->{+TTY} = -t $io unless defined $self->{+TTY};

    my $use_color = ref($self->{+COLOR}) ? 1 : delete($self->{+COLOR});
    $use_color = $self->{+TTY} unless defined $use_color;

    if ($use_color && USE_ANSI_COLOR) {
        $self->{+SHOW_BUFFER} = 1 unless defined $self->{+SHOW_BUFFER};

        if ($use_color) {
            $self->{+COLOR} = {
                DEFAULT_COLOR(),
                TAGS   => {DEFAULT_TAG_COLOR()},
                FACETS => {DEFAULT_FACET_COLOR()},
                JOBS   => [DEFAULT_JOB_COLOR()],
            } unless defined $self->{+COLOR};

            $self->{+JOB_COLORS} = {free => [@{$self->{+COLOR}->{JOBS}}]};
        }
    }
    else {
        $self->{+SHOW_BUFFER} = 0 unless defined $self->{+SHOW_BUFFER};
    }

    $self->{+ECOUNT} //= 0;

    my $reset = $use_color ? Term::ANSIColor::color('reset') : '';
    my $cyan  = $use_color ? Term::ANSIColor::color('cyan')  : '';
    $self->{+_ACTIVE_DISP} = ["[${cyan}INITIALIZING${reset}]", ''];
    $self->{+_FILE_STATS}  = {
        passed  => 0,
        failed  => 0,
        running => 0,
        todo    => 0,
        total   => 0,
    };


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

if ($^C) {
    no warnings 'redefine';
    *write = sub {};
}
sub write {
    my ($self, $e, $num, $f) = @_;
    $f ||= $e->facet_data;

    my $should_show = $self->update_active_disp($f);

    $self->{+ECOUNT}++;

    my $job_id = $f->{harness}->{job_id};
    $self->encoding($f->{control}->{encoding}, $job_id) if $f->{control}->{encoding};

    my $hf = hub_truth($f);
    my $depth = $hf->{nested} || 0;

    return if $depth && (!$self->{+SHOW_BUFFER} || !$self->{+PROGRESS});

    my $lines;
    if (!$self->{+VERBOSE}) {
        if ($depth) {
            $lines = [];
        }
        else {
            $lines = $self->render_quiet($f);
        }
    }
    elsif ($depth) {
        my $tree = $self->render_tree($f, '>');
        $lines = $self->render_buffered_event($f, $tree);
    }
    else {
        my $tree = $self->render_tree($f,);
        $lines = $self->render_event($f, $tree);
    }

    $should_show ||= $lines && @$lines;
    unless ($should_show || $self->{+VERBOSE}) {
        if (my $last = $self->{last_rendered}) {
            return if time - $last < 0.2;
            $self->{last_rendered} = time;
        }
        else {
            $self->{last_rendered} = time;
        }
    }

    push @{$self->{+JOB_COLORS}->{free}} => delete $self->{+JOB_COLORS}->{used}->{$job_id}
        if $job_id && $f->{harness_job_end};

    # Local is expensive! Only do it if we really need to.
    local($\, $,) = (undef, '') if $\ || $,;

    my $io = $self->io($job_id);
    if ($self->{+_BUFFERED}) {
        print $io "\r\e[K";
        $self->{+_BUFFERED} = 0;
    }

    if (!$self->{+VERBOSE}) {
        print $io $_, "\n" for @$lines;
        if ($self->{+TTY} && $self->{+PROGRESS}) {
            print $io $self->render_status($f);
            $self->{+_BUFFERED} = 1;
        }
    }
    elsif ($depth && $lines && @$lines && !$self->{+INTERACTIVE}) {
        print $io $lines->[0];
        $self->{+_BUFFERED} = 1;
    }
    else {
        print $io $_, "\n" for @$lines;
    }

    delete $self->{+JOB_IO}->{$job_id} if $job_id && $f->{harness_job_end};
}

sub finalize {
    my $self = shift;

    my $io = $self->{+IO};
    print $io "\r\e[K" if $self->{+_BUFFERED};

    return;
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

    if (my $task = $f->{harness_job_queued}) {
        $self->{+JOB_NAMES}->{$task->{job_id}} = $task->{job_name} || $task->{job_id};
        $stats->{total}++;
        $stats->{todo}++;
    }

    if ($f->{harness_job_launch}) {
        my $job = $f->{harness_job};
        $self->{+ACTIVE_FILES}->{File::Spec->abs2rel($job->{file})} = $job->{job_name} || $job->{job_id};
        $should_show = 1;
        $stats->{running}++;
        $stats->{todo}--;
        $stats->{started} //= 1;
    }

    if ($f->{harness_job_end}) {
        my $file = $f->{harness_job_end}->{file};
        delete $self->{+ACTIVE_FILES}->{File::Spec->abs2rel($file)};
        $should_show = 1;
        $stats->{running}--;

        if ($f->{harness_job_end}->{fail}) {
            $stats->{failed}++;
        }
        else {
            $stats->{passed}++;
        }
    }

    return $out unless $should_show;

    my $statline = join '|' => (
        $self->_highlight($stats->{passed},  'P', 'green'),
        $self->_highlight($stats->{failed},  'F', 'red'),
        $self->_highlight($stats->{running}, 'R', 'cyan'),
        $self->_highlight($stats->{todo},    'T', 'yellow'),
    );

    $statline = "[$statline]";

    my $active = $self->{+ACTIVE_FILES};

    return $self->{+_ACTIVE_DISP} = [$statline, ''] unless $active && keys %$active;

    my $reset = $self->reset;

    my $str .= "(";
    {
        no warnings 'numeric';
        $str .= join(' ' => map { m{([^/]+)$}; "$active->{$_}:$1" } sort { ($active->{$a} || 0) <=> ($active->{$b} || 0) or $a cmp $b } keys %$active);
    }
    $str .= ")";

    $self->{+_ACTIVE_DISP} = [$statline, $str];

    return 1;
}

sub update_spinner {
    my $self = shift;
    my ($stats) = @_;

    $stats->{spinner} //= '|';
    $stats->{spinner_time} //= time - 1;
    $stats->{blink_time} //= time - 1;
    $stats->{blink} //= '';

    if (time - $stats->{spinner_time} > 0.1) {
        $stats->{spinner_time} = time;
        my $start = substr($stats->{spinner}, 0, 1);
        $stats->{spinner} = '\\' if $start eq '-';
        $stats->{spinner} = '-'  if $start eq '/';
        $stats->{spinner} = '/'  if $start eq '|';
        $stats->{spinner} = '|'  if $start eq '\\';
    }
    elsif(time - $stats->{blink_time} > 0.5) {
        $stats->{blink_time} = time;
        $stats->{blink} = $stats->{blink} ? '' : 'bold bright_';
    }
    else {
        return 0;
    }

    my $yellow = $self->{+COLOR} ? Term::ANSIColor::color($stats->{blink} . 'yellow') : '';
    my $cyan   = $self->{+COLOR} ? Term::ANSIColor::color('cyan')                     : '';
    my $green  = $self->{+COLOR} ? Term::ANSIColor::color('bold bright_green')        : '';
    my $bold   = $self->{+COLOR} ? Term::ANSIColor::color('bold bright_white')        : '';
    my $reset  = $self->reset;

    $self->{+_ACTIVE_DISP} = [
        join(
            '' => (
                $bold  => "[ ",              $reset,
                $green => $stats->{spinner}, $reset,
                ''     => " ",
                $self->{+IS_PERSISTENT}
                ? (
                    $yellow => "Waiting for busy runner", $reset,
                    ''      => " ",
                    $reset  => "(see ",       $reset,
                    $cyan   => "yath status", $reset,
                    $reset  => ")",           $reset,
                    )
                : ($yellow => "INITIALIZING", $reset),
                ''     => " ",
                $green => $stats->{spinner}, $reset,
                $bold  => " ]",              $reset,
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
    return sprintf('%s%s:%d%s', Term::ANSIColor::color($color), $label, $val, $self->reset);
}


sub colorstrip {
    my $self = shift;
    my ($str) = @_;

    return $str unless USE_ANSI_COLOR;
    return Term::ANSIColor::colorstrip($str);
}

sub render_status {
    my $self = shift;

    my $reset = $self->reset;
    my $cyan = $self->{+COLOR} ? Term::ANSIColor::color('cyan') : '';

    my $str = "$self->{+_ACTIVE_DISP}->[0] Events: $self->{+ECOUNT} ${cyan}$self->{+_ACTIVE_DISP}->[1]${reset}";

    my $max = term_size() || 80;

    if (length($str) > $max) {
        my $nocolor = $self->colorstrip($str);
        $str = substr($nocolor, 0, $max - 8) . " ...)$reset" if length($nocolor) > $max;
        $str =~ s/\(/$cyan(/;
        $str =~ s/^\[[^\]]+\]/$self->{+_ACTIVE_DISP}->[0]/;
    }

    return $str;
}

sub render_buffered_event {
    my $self = shift;
    my ($f, $tree) = @_;

    my $comp = $self->{+COMPOSER}->render_one_line($f) or return;

    return unless @$comp;
    return [$self->build_line($tree, @$comp)];
}

sub render_event {
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

sub render_quiet {
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
    return $self->{+COLOR} ? $self->{+COLOR}->{reset} : '';
}

sub job_color {
    my $self = shift;
    my ($id, $set) = @_;
    return '' unless $self->{+JOB_COLORS};
    return $self->{+JOB_COLORS}->{used}->{$id} || '' unless $set;
    return $self->{+JOB_COLORS}->{used}->{$id} ||= shift @{$self->{+JOB_COLORS}->{free}} || '';
}

sub render_tree {
    my $self = shift;
    my ($f, $char) = @_;
    $char ||= '|';

    my $job = '';
    if ($f->{harness} && $f->{harness}->{job_id}) {
        my $id = $f->{harness}->{job_id};
        my $name = $self->{+JOB_NAMES}->{$id};

        my ($color, $reset) = ('', '');
        if ($self->{+JOB_COLORS}) {
            $color = $self->job_color($id, 'set');
            $reset = $self->reset;
        }

        my $len = length($name);
        if (!$self->{+JOB_LENGTH} || $len > $self->{+JOB_LENGTH}) {
            $self->{+JOB_LENGTH} = $len;
        }
        else {
            $len = $self->{+JOB_LENGTH};
        }

        $job = sprintf("%sjob %${len}s%s ", $color, $name, $reset || '');
    }

    my $hf = hub_truth($f);
    my $depth = $hf->{nested} || 0;

    my @pipes = (' ', map $char, 1 .. $depth);
    return join(' ' => $job, @pipes) . ' ';
}

sub build_line {
    my $self = shift;
    my ($tree, $facet, $tag, $text) = @_;

    $tree ||= '';
    $tag  ||= '';
    $text ||= '';
    chomp($text);

    substr($tree, -2, 1, '+') if $facet eq 'assert';

    $tag = substr($tag, 0 - TAG_WIDTH, TAG_WIDTH) if length($tag) > TAG_WIDTH;

    my $max = $self->{+TTY} && !$self->{+NO_WRAP} ? (term_size() || 80) : undef;
    my $color = $self->{+COLOR};
    my $reset = $self->reset;
    my $tcolor = $color ? $color->{TAGS}->{$tag} || $color->{FACETS}->{$facet} || '' : '';

    my ($ps, $pe) = @{$FACET_TAG_BORDERS{$facet} || $FACET_TAG_BORDERS{default}};

    $tag = uc($tag);
    my $length = length($tag);
    if ($length > TAG_WIDTH) {
        $tag = substr($tag, 0, TAG_WIDTH);
    }
    elsif($length < TAG_WIDTH) {
        my $pad = (TAG_WIDTH - $length) / 2;
        my $padl = $pad + (TAG_WIDTH - $length) % 2;
        $tag = (' ' x $padl) . $tag . (' ' x $pad);
    }

    my $start;
    if ($color) {
        my $border = $color->{tag_border} || '';
        $start = "${reset}${border}${ps}${reset}${tcolor}${tag}${reset}${border}${pe}${reset}";
    }
    else {
        $start = "${ps}${tag}${pe}";
    }
    $start .= "  ";

    if ($tree) {
        if ($color) {
            my $trcolor = $color->{tree} || '';
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
        if(@lines > 1 && $max && length("$ps$tag$pe  $tree$line") > $max) {
            @out = ();
            last;
        }

        if ($color) {
            push @out => "${start}${tcolor}${line}$reset";
        }
        else {
            push @out => "${start}${line}";
        }
    }

    return @out if @out;

    return (
        "$start----- START -----",
        $text,
        "$start------ END ------",
    ) unless $color;

    my $blob = $color->{blob} || '';
    return (
        "$start${blob}----- START -----$reset",
        "${tcolor}${text}${reset}",
        "$start${blob}------ END ------$reset",
    );
}

sub render_parent {
    my $self = shift;
    my ($f, $tree, %params) = @_;

    my $meth = $params{quiet} ? 'render_quiet' : 'render_event';

    my @out;
    for my $sf (@{$f->{parent}->{children}}) {
        $sf->{harness} ||= $f->{harness};
        my $tree = $self->render_tree($sf);
        push @out => @{$self->$meth($sf, $tree)};
    }

    return unless @out;

    push @out => (
        $self->build_line("$tree^", 'parent', '', ''),
    );

    return @out;
}


sub DESTROY {
    my $self = shift;

    my $io = $self->{+IO} or return;

    # Local is expensive! Only do it if we really need to.
    local($\, $,) = (undef, '') if $\ || $,;

    print $io Term::ANSIColor::color('reset')
        if USE_ANSI_COLOR;

    print $io "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Test2 - An alternative to TAP, used by Test2::Harness.

=head1 DESCRIPTION

This formatter is the primary formatter used for final result rendering when
you use Test2::Harness. This formatter is NOT designed to have its output
consumed by code/machine/harnesses. The goal of this formatter is to have
output that is easily read by humans.

=head1 SYNOPSIS

If you are running a test directly with perl and want to use this formatter:

    $ perl -MTest2::Formatter::Test2 path/to/test.t

You could also use the module directly in your test, but that is not
recommended as your test would then be unable to be run via prove or other
harnesses.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
