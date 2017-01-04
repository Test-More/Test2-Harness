package Test2::Harness::Renderer::EventStream;
use strict;
use warnings;

our $VERSION = '0.000014';

use Test2::Util::HashBase qw/color verbose jobs slots parallel clear out_std watch colors graph_colors counter/;
use Term::ANSIColor();
use List::Util qw/first shuffle/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/sleep/;
use Test2::Util::Term qw/term_size/;

my @DEFAULT_GRAPH_COLORS = qw{
           blue        yellow        cyan        magenta
    bright_blue bright_yellow bright_cyan bright_magenta
};

my %DEFAULT_COLORS = (
    blob    => 'bold bright_black on_white',
    tag     => 'bold bright_white',
    mark    => 'bold bright_white',
    diag    => 'yellow',
    stderr  => 'yellow',
    fail    => 'bold red',
    failed  => 'bold red',
    parser  => 'magenta',
    unknown => 'magenta',
    pass    => 'green',
    passed  => 'bold green',
    reset   => 'reset',
    skip    => 'bold white on_blue',
    skipall => 'bold white on_blue',
    todo    => 'bold black on_bright_yellow',
    file    => 'bold bright_white',
);

my %EXTENDED_COLORS = (
    %DEFAULT_COLORS,
    plan   => 'cyan',
    note   => 'blue',
    stdout => 'blue',
);

BEGIN {
    for my $sig (qw/INT TERM/) {
        my $old = $SIG{$sig} || sub {
            $SIG{$sig} = 'DEFAULT';
            kill $sig, $$;
        };

        $SIG{$sig} = sub {
            print STDOUT Term::ANSIColor::color('reset') if -t STDOUT;
            print STDERR Term::ANSIColor::color('reset') if -t STDERR;
            $old->();
        };
    }
}

END {
    print STDOUT Term::ANSIColor::color('reset') if -t STDOUT;
    print STDERR Term::ANSIColor::color('reset') if -t STDERR;
}

sub init {
    my $self = shift;
    $self->{+JOBS}  = {};
    $self->{+SLOTS} = [];
    $self->{+CLEAR} = 0;

    my $fh = $self->{+OUT_STD} ||= do {
        open( my $out, '>&', STDOUT ) or die "Can't dup STDOUT:  $!";

        my $old = select $out;
        $| = 1;
        select $old;

        $out;
    };

    $self->{+COUNTER} = 0;

    my $is_term = -t $fh;
    $self->{+COLOR} = $is_term ? 1 : 0 unless defined $self->{+COLOR};
    $self->{+WATCH} = $is_term ? 1 : 0 unless defined $self->{+WATCH};
    if (($is_term || $self->{+COLOR} || $self->{+WATCH}) && $^O eq 'MSWin32') {
        eval { require Win32::Console::ANSI } and Win32::Console::ANSI->import;
    }

    my $colors =
          $self->{+COLOR} > 1 ? \%EXTENDED_COLORS
        : $self->{+COLOR}     ? \%DEFAULT_COLORS
        :                       {};

    my $graph_colors = $self->{+COLOR} ? [@DEFAULT_GRAPH_COLORS] : [];

    $self->{+COLORS}       ||= {map { $_ => eval { Term::ANSIColor::color($colors->{$_}) } || '' } grep {$colors->{$_}} keys %$colors, 'reset'};
    $self->{+GRAPH_COLORS} ||= [map { eval { Term::ANSIColor::color($_) } || ''                  } grep {$_} @$graph_colors];
}

sub paint {
    my $self = shift;
    my $string = "";

    my $colors = $self->{+COLORS};
    my $graph  = $self->{+GRAPH_COLORS};
    my $jobs   = $self->{+JOBS};

    if ($self->{+CLEAR}) {
        $string .= "\e[K";
        $self->{+CLEAR}--;
    }

    for my $i (@_) {
        unless (ref($i)) {
            $string .= $i;
            next;
        }

        my ($c, $s, $r) = @$i;
        $r = 1 if @$i < 3;
        if ($c =~ m/^\d+$/) {
            $string .= $graph->[$jobs->{$c}->{slot} % @$graph] || '' if @$graph
        }
        else {
            $string .= $colors->{lc($c)} || '';
        }
        $string .= $s;
        $string .= $colors->{reset} || '' if $r;
    }

    my $fh = $self->{+OUT_STD};

    print $fh $string;
}

sub encoding {
    my $self = shift;
    my ($enc) = @_;

    my $fh = $self->{+OUT_STD};
    # https://rt.perl.org/Public/Bug/Display.html?id=31923
    # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
    # order to avoid the thread segfault.
    if ($enc =~ m/^utf-?8$/i) {
        binmode($fh, ":utf8");
    }
    else {
        binmode($fh, ":encoding($enc)");
    }
}

sub summary {
    my $self = shift;
    my ($results) = @_;

    my @fail = grep {!$_->passed} @$results;

    if (@fail) {
        $self->paint("\n", ['failed', "=== FAILURE SUMMARY ===\n", 0]);
        $self->paint(map { " * " . $_->name . "\n" } @fail);
    }
    else {
        $self->paint("\n", ['passed', "=== ALL TESTS SUCCEEDED ===\n", 0]);
    }

    $self->paint(['reset', '', 0], "\n");
}

sub listen {
    my $self = shift;
    sub { $self->process(@_) };
}

sub init_job {
    my $self = shift;
    my ($j) = @_;

    my $jobs  = $self->{+JOBS};
    my $slots = $self->{+SLOTS};

    my $slot;
    for my $s (0 .. @$slots) {
        $slot = $s unless defined $slots->[$s];
        last if defined $slot;
    }

    $slots->[$slot] = $j;

    return $jobs->{$j} = {slot => $slot};
}

sub end_job {
    my $self = shift;
    my ($j) = @_;

    my $job = delete $self->{+JOBS}->{$j};
    $self->{+SLOTS}->[$job->{slot}] = undef;
}

sub update_state {
    my $self = shift;
    my ($j, $event) = @_;

    $self->{+COUNTER}++;

    my $jobs = $self->{+JOBS};
    my $job = $jobs->{$j} ||= $self->init_job($j);
    $job->{counter}++;

    $self->encoding($event->encoding) if $event->isa('Test2::Event::Encoding');
}

sub pick_renderer {
    my $self = shift;
    my ($event) = @_;

    my $n = $event->nested || 0;

    return 'render' if $n < 0;

    if ($n == 0) {
        return 'render'         unless $event->subtest_id;
        return 'render_subtest' unless $event->in_subtest;
    }

    return 'render_orphan' unless $event->in_subtest;
    return 'preview'       if $self->{+WATCH};

    return;
}

sub process {
    my $self = shift;
    my ($j, $event) = @_;

    my $job_id = $j->id;
    $self->update_state($job_id, $event);

    my $job = $self->{+JOBS}->{$job_id};

    my $is_end = $event->isa('Test2::Event::ProcessFinish');

    if ($event->isa('Test2::Event::ProcessStart') && !$self->{+VERBOSE}) {
        $job->{start} = $event;
    }
    else {
        my @to_print = $self->_process($job_id, $event, $is_end);
        $self->paint(@to_print) if @to_print;
    }

    $self->do_watch;

    $self->end_job($job_id) if $is_end;
}

sub _process {
    my $self = shift;
    my ($j, $event, $is_end) = @_;
    my $job = $self->{+JOBS}->{$j};

    my $meth     = $self->pick_renderer($event) or return;
    my @to_print = $self->$meth($j, $event)     or return;
    my @start = $job->{start} ? $self->render($j, delete $job->{start}) : ();

    return (@start, @to_print) unless $is_end;

    my @errors = $self->_plan_errors($event->result->events, 0) or return @to_print;
    my @tree = $self->tree($j, $event);

    @errors = map {(
        ['tag', '['], ['fail',' PLAN '], ['tag', ']'],
        '  ', @tree, '  ',
        ['fail', $_],
        "\n",
    )} @errors;

    return (@start, @errors, @to_print);
}

sub do_watch {
    my $self = shift;
    return unless $self->{+WATCH};
    return if $self->{+VERBOSE};

    my $jobs = $self->{+JOBS};

    my $size = length($self->{+COUNTER});

    $self->paint(" Events Seen: ", $self->{+COUNTER}, "\r");
    $self->{+CLEAR} = 1;
}

sub _tag {
    my $self = shift;
    my ($event) = @_;

    return if $event->no_display;

    return ("LAUNCH", 'file')
        if $event->isa('Test2::Event::ProcessStart');

    if ($event->isa('Test2::Event::ParserSelect')) {
        return unless $self->{+VERBOSE};
        return ('PARSER', 'parser_select');
    }

    if ($event->isa('Test2::Event::Subtest')) {
        return ("FAILED", 'failed') if $event->causes_fail;

        my $n = $event->nested || 0;
        return unless $self->{+VERBOSE} || $n < 0;

        my ($plan) = (grep { $_->isa('Test2::Event::Plan') } @{$event->subevents})[0];
        if ($plan && $plan->directive && $plan->directive eq 'SKIP') {
            return ("SKIP!!", 'skipall');
        }

        return ("PASSED", 'passed');
    }

    if ($event->isa('Test2::Event::ProcessFinish')) {
        return ("NOTEST", "skipall") unless $event->result->ran_tests;
        return ("PASSED", 'passed') if $event->result->passed;
        return ("FAILED", 'failed');
    }

    if ($event->isa('Test2::Event::Plan')) {
        if ($event->directive eq 'SKIP') {
            return ("SKIP!!", 'skipall');
        }
        return unless $self->{+VERBOSE};
        return (" PLAN ", 'plan');
    }

    if ($event->isa('Test2::Event::Encoding')) {
        return unless $self->{+VERBOSE};
        return ('ENCODE', 'encoding');
    }

    if ($event->isa('Test2::Event::UnknownStdout') || $event->isa('Test2::Event::UnknownStderr')) {
        return unless defined $event->output;

        return ("STDERR", 'stderr') if $event->isa('Test2::Event::UnknownStderr');
        return (" DIAG ", 'diag')   if $event->diagnostics;

        return unless $self->{+VERBOSE};
        return ("STDOUT", 'stdout');
    }

    if ($event->isa('Test2::Event::UnexpectedProcessExit') || $event->isa('Test2::Event::TimeoutReset')) {
        return ("PARSER", 'parser');
    }

    if ($event->increments_count) {
        if ($self->{+VERBOSE}) {
            return ("  OK  ", 'skip') if $event->can('reason') && defined $event->reason;
            return ("NOT OK", 'todo') if $event->can('todo') && defined $event->todo;
            # The event is a failure but something overrode that - this would
            # be a failure inside a subtest marked as todo.
            return ("NOT OK", 'todo') if !$event->pass         && $event->effective_pass;
            return ("  OK  ", 'pass') unless $event->causes_fail;
        }

        return ("NOT OK", 'fail') if $event->causes_fail;
        return;
    }

    if ($event->can('message')) {
        return (" DIAG ", 'diag') if $event->diagnostics;
        return unless $self->{+VERBOSE};
        return (" NOTE ", 'note');
    }

    return unless $self->{+VERBOSE} || $event->diagnostics;
    return ("PARSER", 'parser') if $event->isa('Test2::Event::ParseError');

    return unless defined $event->summary && $event->summary =~ /\S/;

    return (" ???? ", 'unknown');
}

sub tag {
    my $self = shift;
    my ($event) = @_;

    my ($val, $color) = $self->_tag($event);

    return unless $val;
    return (
        ['tag', '['],
        [$color, $val],
        ['tag', ']'],
    );
}

sub tree {
    my $self = shift;
    my ($j, $event) = @_;

    # Get mark
    my $mark = '+';
    if (!$event) {
        $mark = '|';
    }
    else {
        my $n = $event->nested || 0;
        $mark = '_' if $event->isa('Test2::Event::ProcessStart');
        $mark = '=' if $event->isa('Test2::Event::Subtest') && $n < 0;
        $mark = '=' if $event->isa('Test2::Event::ProcessFinish');
    }

    my $jobs   = $self->{+JOBS};
    my $slots  = $self->{+SLOTS};

    my @marks;
    for my $s (@$slots) {
        if (!defined($s)) {
            push @marks => (' ', ' ');
            next;
        }

        unless ($jobs->{$s}->{counter} > 1 || $j == $s) {
            push @marks => ([$s, ':'], ' ');
            next;
        }

        if ($s == $j && $mark ne '|') {
            push @marks => ([$mark eq '+' ? $s : 'mark', $mark], ' ');
        }
        else {
            push @marks => ([$s, '|'], ' ');
        }
    }
    pop @marks;
    return @marks;
}

sub painted_length {
    my $self = shift;
    my $str = join '' => map { ref($_) ? $_->[1] : $_ } @_;
    return length($str);
}

sub event_summary {
    my $self = shift;
    my ($event, $start) = @_;

    my ($val, $color) = $self->_tag($event);

    my $summary = $event->summary;

    $summary =~ s/^[\n\r]+//g;
    my @lines = grep {defined $_ && length $_} split /[\n\r]+/, $summary;
    @lines = ('') unless @lines;

    my $len = $self->painted_length(@$start) + 1;
    my $term_size = term_size();

    my @blob;
    if (grep { $term_size <= $len + length($_) } @lines) {
        @lines = ( ['blob', '----- START -----'] );
        @blob  = (
            [$color, $summary],
            "\n",
            @$start,
            ['blob', '------ END ------'],
            "\n",
        );
    }
    else {
        @lines = map { [$color, $_] } @lines;
    }

    return (\@lines, \@blob);
}

sub render {
    my $self = shift;
    my ($j, $event, @nest) = @_;

    # If there is no tag then we do not render it.
    my @tag = $self->tag($event) or return;
    my @tree = $self->tree($j, $event);
    my @start = (@tag, '  ', @tree, '  ', @nest);

    my ($summary, $blob) = $self->event_summary($event, \@start);

    my @out;
    push @out => (@start, $_, "\n") for @$summary;
    push @out => @$blob if @$blob;

    return @out;
}

sub render_orphan {
    my $self = shift;
    my ($j, $event) = @_;

    # If there is no tag then we do not render it.
    my @tag = $self->tag($event) or return;
    my @tree = $self->tree($j, $event);
    my @start = (@tag, '  ', @tree, '  ', [$j, ("> " x $event->nested)]);

    my ($summary, $blob) = $self->event_summary($event, \@start);

    my @out;
    push @out => (@start, $_, "\n") for @$summary;
    push @out => @$blob if @$blob;

    return @out;
}

sub preview {
    my $self = shift;
    my ($j, $event) = @_;

    # If there is no tag then we do not render it.
    my @tag = $self->tag($event) or return;
    my @tree = $self->tree($j, $event);
    my @start = (@tag, '  ', @tree, '  ', [$j, ("> " x $event->nested)]);

    my ($summary) = $self->event_summary($event, \@start);

    $self->{+CLEAR} = 2;
    return (@start, $summary->[-1], "\r");
}

sub render_subtest {
    my $self = shift;
    my ($j, $event) = @_;

    my @out = $self->render($j, $event);

    my @todo = @{$event->subevents};
    my @stack = ($event);

    while (my $e = shift @todo) {
        my $nest = "";

        if ($e->subtest_id) {
            unshift @todo => @{$e->subevents};
            push @stack => $e;

            $nest = '| ' x ($e->nested - 1);
            $nest .= "+-";
        }
        else {
            $nest = '| ' x $e->nested;
        }

        if (!@todo || (($todo[0]->in_subtest || '') ne ($e->in_subtest || '') && !$e->subtest_id)) {
            push @out => $self->render($j, $e, [$j, $nest]);

            my @tree = $self->tree($j, $e);

            if (my $st = pop @stack) {
                push @out => (
                    ['tag', '['], ['fail', ' PLAN '], ['tag', ']'],
                    '  ', @tree, '  ',
                    [$j,     $nest],
                    ['fail', $_],
                    "\n",
                ) for $self->_plan_errors($st->subevents, ($st->nested || 0) + 1);
            }

            if (@out && $self->{+VERBOSE}) {
                my $n2 = '| ' x ($e->nested - 1);
                push @out => (
                    "          ", @tree, "  ",
                    [$j, "$n2^"],
                    "\n",
                );
            }
        }
        else {
            push @out => $self->render($j, $e, [$j, $nest]);
        }
    }

    return @out;
}

sub _plan_errors {
    my $self   = shift;
    my $events = shift;
    my $nested = shift;

    my @errors;

    unless ($nested || grep { $_->isa('Test2::Event::ProcessStart') } @{$events}) {
        push @errors => 'No process start event was seen!';
        return;
    }

    my @plans = grep { ($_->nested || 0) == $nested && $_->isa('Test2::Event::Plan') } @{$events};

    unless (@plans) {
        push @errors => 'No plan was ever set.';
        return;
    }

    push @errors => 'Multiple plans were set.'
        if @plans > 1;

    push @errors => 'Plan must come before or after all testing, not in the middle.'
        unless $plans[0] == $events->[0] || $plans[0] == $events->[-1];

    my $max = ($plans[0]->sets_plan)[0];

    my $total = grep { ($_->nested || 0) == $nested && $_->increments_count } @{$events};
    return if $max == $total;
    push @errors => "Planned to run $max test(s) but ran $total.";

    return @errors;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Renderer::EventStream - EventStream renderer.

=head1 DESCRIPTION

This is used to provide pretty/colorful output.

The output looks like this:

    [LAUNCH]  _  t/units/Yath.t
    [PARSER]  +  Test2::Harness::Parser::EventStream
    [ NOTE ]  +  Seeded srand with seed '20160524' from local date.
    [ENCODE]  +  utf8
    [  OK  ]  +  App::Yath->can(...)
    [PASSED]  +  expand_files
    [  OK  ]  +  | found test files
    [  OK  ]  +  | All files are in t/
    [  OK  ]  +  | Specifying nothing is the same as saying 't'
    [  OK  ]  +  | A single file does not expand
    [  OK  ]  +  | Excluded the specified file (t/use_harness.t)
    [ PLAN ]  +  | Plan is 5 assertions
              +  ^
    [PASSED]  +  args_and_init
    [  OK  ]  +  | Got expected default structure
    [  OK  ]  +  | Got expected structure
    [  OK  ]  +  | Got expected default structure + switches
    [  OK  ]  +  | Cannot combine preload and switches
    [ PLAN ]  +  | Plan is 4 assertions
              +  ^
    [PASSED]  +  run
    [  OK  ]  +  | no failures
    [  OK  ]  +  | Got the result in the renderer
    [ PLAN ]  +  | Plan is 2 assertions
              +  ^
    [ PLAN ]  +  Plan is 4 assertions
    [PASSED]  =  t/units/Yath.t
    
    === ALL TESTS SUCCEEDED ===

The first column is a brief tag for each event. The second column is job
information, this is more useful when running multiple tests in parallel. The
right hand side is the summary of each event as it is handled. Subtests are
rendered as a tree.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
