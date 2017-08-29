package Test2::Formatter::Test2;
use strict;
use warnings;

our $VERSION = '0.001001';

use Scalar::Util qw/blessed/;
use List::Util qw/shuffle/;
use Test2::Util::Term qw/term_size/;
use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;
use Test2::Util qw/IS_WIN32/;

BEGIN { require Test2::Formatter; our @ISA = qw(Test2::Formatter) }

sub import {
    my $class = shift;
    return if $ENV{HARNESS_ACTIVE};
    $class->SUPER::import;
}

use Test2::Util::HashBase qw{
    -last_depth
    -_buffered
    -io
    -_encoding
    -show_buffer
    -color
    -tty
    -verbose
    -job_length
    -ecount
    -job_colors
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
        'PASSED'   => Term::ANSIColor::color('bold bright_green'),
        'FAILED'   => Term::ANSIColor::color('bold bright_red'),
        'REASON'   => Term::ANSIColor::color('magenta'),
        'TIMEOUT'  => Term::ANSIColor::color('magenta'),
    );
}

sub DEFAULT_FACET_COLOR() {
    return (
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
sub DEFAULT_JOB_COLOR() {
    return map { Term::ANSIColor::color($_) } (
        'bold green on_blue',
        'bold blue on_white',
        'bold black on_cyan',
        'bold green on_bright_black',
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
        'bold bright_black on_cyan',
        'bold bright_green on_bright_black',
        'bold blue on_green',
        'bold bright_cyan on_blue',
        'bold bright_blue on_cyan',
        'bold bright_blue on_green',
        'bold bright_white on_blue',
        'bold bright_cyan on_bright_black',
        'bold bright_white on_cyan',
        'bold bright_white on_green',
    );
}

sub DEFAULT_COLOR() {
    return (
        reset      => Term::ANSIColor::color('reset'),
        blob       => Term::ANSIColor::color('bold bright_black on_white'),
        tree       => Term::ANSIColor::color('bold bright_white'),
        tag_border => Term::ANSIColor::color('bold bright_white'),
    );
}

sub init {
    my $self = shift;

    $self->{+VERBOSE} = 1 unless defined $self->{+VERBOSE};

    $self->{+JOB_LENGTH} ||= 2;

    unless ($self->{+IO}) {
        open(my $io, '>&', STDOUT) or die "Can't dup STDOUT:  $!";
        $self->{+IO} = $io;
    }

    my $io = $self->{+IO};
    $io->autoflush(1);

    $self->{+TTY} = -t $io unless defined $self->{+TTY};

    if ($self->{+TTY} && USE_ANSI_COLOR) {
        $self->{+SHOW_BUFFER} = 1 unless defined $self->{+SHOW_BUFFER};
        $self->{+COLOR} = {
            DEFAULT_COLOR(),
            TAGS   => {DEFAULT_TAG_COLOR()},
            FACETS => {DEFAULT_FACET_COLOR()},
            JOBS   => [DEFAULT_JOB_COLOR()],
        } unless defined $self->{+COLOR};

        $self->{+JOB_COLORS} = {free => [@{$self->{+COLOR}->{JOBS}}]};
    }
    else {
        $self->{+SHOW_BUFFER} = 0 unless defined $self->{+SHOW_BUFFER};
    }
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;

        # https://rt.perl.org/Public/Bug/Display.html?id=31923
        # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
        # order to avoid the thread segfault.
        if ($enc =~ m/^utf-?8$/i) {
            binmode($self->{+IO}, ":utf8");
        }
        else {
            binmode($self->{+IO}, ":encoding($enc)");
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

    $self->{+ECOUNT}++;

    $self->encoding($f->{control}->{encoding}) if $f->{control}->{encoding};

    my $depth = $f->{trace}->{nested};

    return if $depth && !$self->{+SHOW_BUFFER};

    my $lines;
    if (!$self->{+VERBOSE}) {
        unless ($depth) {
            my $tree = $self->render_tree($f,);
            $lines = $self->render_quiet($f, $tree);
        }

        $lines ||= [];
    }
    elsif ($depth) {
        my $tree = $self->render_tree($f, '>');
        $lines = $self->render_buffered_event($f, $tree);
    }
    else {
        my $tree = $self->render_tree($f,);
        $lines = $self->render_event($f, $tree);
    }

    my $job_id = $f->{harness}->{job_id};
    push @{$self->{+JOB_COLORS}->{free}} => delete $self->{+JOB_COLORS}->{used}->{$job_id}
        if $job_id && $f->{harness_job_end};

    return unless ($lines && @$lines) || !$self->{+VERBOSE};

    my $io = $self->{+IO};
    if ($self->{+_BUFFERED}) {
        print $io "\r\e[K";
        $self->{+_BUFFERED} = 0;
    }

    if (!$self->{+VERBOSE}) {
        print $io $_, "\n" for @$lines;
        print $io $self->render_ecount($f);
        $self->{+_BUFFERED} = 1;
    }
    elsif ($depth) {
        print $io $lines->[0];
        $self->{+_BUFFERED} = 1;
    }
    else {
        print $io $_, "\n" for @$lines;
    }

    $io->flush;
}

sub render_ecount {
    my $self = shift;
    return "Events seen: " . $self->{+ECOUNT};
}

sub render_buffered_event {
    my $self = shift;
    my ($f, $tree) = @_;

    return [$self->render_halt($f, $tree)] if $f->{control}->{halt};
    return [$self->render_assert($f, $tree)] if $f->{assert};
    return [$self->render_errors($f, $tree)] if $f->{errors};
    return [$self->render_plan($f, $tree)] if $f->{plan};
    return [$self->render_info($f, $tree)] if $f->{info};

    return [$self->render_about($f, $tree)] if $f->{about};

    return;
}

sub render_event {
    my $self = shift;
    my ($f, $tree) = @_;

    my @out;

    push @out => $self->render_halt($f, $tree) if $f->{control}->{halt};
    push @out => $self->render_plan($f, $tree) if $f->{plan};

    if ($f->{assert}) {
        push @out => $self->render_assert($f, $tree);
        push @out => $self->render_debug($f, $tree) unless $f->{assert}->{pass} || $f->{assert}->{no_debug};
        push @out => $self->render_amnesty($f, $tree) if $f->{amnesty} && ! $f->{assert}->{pass};
    }

    push @out => $self->render_info($f, $tree) if $f->{info};
    push @out => $self->render_errors($f, $tree) if $f->{errors};
    push @out => $self->render_parent($f, $tree) if $f->{parent};

    push @out => $self->render_about($f, $tree)
        if $f->{about} && !(@out || grep { $f->{$_} } qw/stop plan info nest assert/);

    return \@out;
}

sub render_quiet {
    my $self = shift;
    my ($f, $tree) = @_;

    my @out;

    push @out => $self->render_halt($f, $tree) if $f->{control}->{halt};

    if ($f->{assert} && !$f->{assert}->{pass} && !$f->{amnesty}) {
        push @out => $self->render_assert($f, $tree);
        push @out => $self->render_debug($f, $tree) unless $f->{assert}->{pass} || $f->{assert}->{no_debug};
        push @out => $self->render_amnesty($f, $tree) if $f->{amnesty} && ! $f->{assert}->{pass};
    }

    if ($f->{info}) {
        my $if = { %$f, info => [grep { $_->{debug} || $_->{important} } @{$f->{info}}] };
        push @out => $self->render_info($if, $tree) if @{$if->{info}};
    }

    push @out => $self->render_errors($f, $tree) if $f->{errors};
    push @out => $self->render_parent($f, $tree, quiet => 1) if $f->{parent} && !$f->{amnesty};

    return \@out;
}

sub render_tree {
    my $self = shift;
    my ($f, $char) = @_;
    $char ||= '|';

    my $job = '';
    if ($f->{harness} && $f->{harness}->{job_id}) {
        my $id = $f->{harness}->{job_id};

        my ($color, $reset) = (''. '');
        if ($self->{+JOB_COLORS}) {
            $color = $self->{+JOB_COLORS}->{used}->{$id} ||= shift @{$self->{+JOB_COLORS}->{free}} || '';
            $reset = $self->{+COLOR}->{reset};
        }

        my $len = length($id);
        if (!$self->{+JOB_LENGTH} || $len > $self->{+JOB_LENGTH}) {
            $self->{+JOB_LENGTH} = $len;
        }
        else {
            $len = $self->{+JOB_LENGTH};
        }

        $job = sprintf("%sjob %0${len}u%s ", $color, $id, $reset || '');
    }

    my $depth = $f->{trace}->{nested} || 0;

    my @pipes = (' ', map $char, 1 .. $depth);
    return join(' ' => $job, @pipes) . ' ';
}

sub build_line {
    my $self = shift;
    my ($facet, $tag, $tree, $text, $ps, $pe) = @_;

    $tree ||= '';
    $tag  ||= '';
    $text ||= '';
    chomp($text);

    substr($tree, -2, 1, '+') if $facet eq 'assert';

    my $max = term_size() || 80;
    my $color = $self->{+COLOR};
    my $reset = $color ? $color->{reset} || '' : '';
    my $tcolor = $color ? $color->{TAGS}->{$tag} || $color->{FACETS}->{$facet} || '' : '';

    ($ps, $pe) = ('[', ']') unless $ps;

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
        if( length("$ps$tag$pe  $tree$line") > $max) {
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

sub render_halt {
    my $self = shift;
    my ($f, $tree) = @_;

    return $self->build_line('control', 'HALT', $tree, $f->{control}->{details});
}

sub render_plan {
    my $self = shift;
    my ($f, $tree) = @_;

    my $plan = $f->{plan};
    return $self->build_line('plan', 'NO  PLAN', $tree, $f->{plan}->{details}) if $plan->{none};

    if ($plan->{skip}) {
        return $self->build_line('plan', 'SKIP ALL', $tree, $f->{plan}->{details})
            if $f->{plan}->{details};

        return $self->build_line('plan', 'SKIP ALL', $tree, "No reason given");
    }

    return $self->build_line('plan', 'PLAN', $tree, "Expected asserions: $f->{plan}->{count}");
}

sub render_assert {
    my $self = shift;
    my ($f, $tree) = @_;

    substr($tree, -2, 2, '+~') if $f->{parent};

    my $name = $f->{assert}->{details} || '<UNNAMED ASSERTION>';

    return $self->build_line('assert', 'PASS', $tree, $name)
        if $f->{assert}->{pass};

    return $self->build_line('assert', '! PASS !', $tree, $name)
        if $f->{amnesty} && @{$f->{amnesty}};

    return $self->build_line('assert', 'FAIL', $tree, $name)
}

sub render_amnesty {
    my $self = shift;
    my ($f, $tree) = @_;

    my %seen;
    return map {
        $seen{join '' => @{$_}{qw/tag details/}}++
            ? ()
            : $self->build_line('amnesty', $_->{tag}, $tree, $_->{details}, '{', '}');
    } @{$f->{amnesty}};
}

sub render_debug {
    my $self = shift;
    my ($f, $tree) = @_;

    my $name  = $f->{assert}->{details};
    my $trace = $f->{trace};

    my $debug;
    if ($trace) {
        $debug = $trace->{details};
        if(!$debug && $trace->{frame}) {
            my $frame = $trace->{frame};
            $debug = "$frame->[1] line $frame->[2]";
        }
    }

    $debug ||= "[No trace info available]";

    chomp($debug);

    return $self->build_line('trace', 'DEBUG', $tree, $debug);
}

sub render_info {
    my $self = shift;
    my ($f, $tree) = @_;

    return map {
        my $details = $_->{details} || '';

        my $msg;
        if (ref($details)) {
            require Data::Dumper;
            my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
            chomp($msg = $dumper->Dump);
        }
        else {
            chomp($msg = $details);
        }

        $self->build_line('info', $_->{tag}, $tree, $details, '(', ')')
    } @{$f->{info}};
}

sub render_about {
    my $self = shift;
    my ($f, $tree) = @_;

    return unless $f->{about} && $f->{about}->{package} && $f->{about}->{details};

    my $type = substr($f->{about}->{package}, 0 - TAG_WIDTH, TAG_WIDTH);

    return $self->build_line('info', $type, $tree, $f->{about}->{details});
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
        $self->build_line('parent', '', "$tree^", '', ' ', ' '),
    );

    return @out;
}


sub render_errors {
    my $self = shift;
    my ($f, $tree) = @_;

    return map {
        my $details = $_->{details};

        my $msg;
        if (ref($details)) {
            require Data::Dumper;
            my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
            chomp($msg = $dumper->Dump);
        }
        else {
            chomp($msg = $details);
        }

        $self->build_line('error', $_->{fail} ? 'FATAL' : 'ERROR', $tree, $details, '<', '>')
    } @{$f->{errors}};
}

sub DESTORY {
    my $self = shift;

    my $io = $self->{+IO} or return;

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

=back

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
