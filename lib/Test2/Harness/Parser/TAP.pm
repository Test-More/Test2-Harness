package Test2::Harness::Parser::TAP;
use strict;
use warnings;

our $VERSION = '0.000014';

use Test2::Event::Bail;
use Test2::Event::Diag;
use Test2::Event::Encoding;
use Test2::Event::Exception;
use Test2::Event::Note;
use Test2::Event::Ok;
use Test2::Event::ParseError;
use Test2::Event::Plan;
use Test2::Event::Skip;
use Test2::Event::Subtest;
use Test2::Event::TAP::Version;
use Test2::Event::UnknownStderr;
use Test2::Event::UnknownStdout;
use Test2::Event::Waiting;
use Test2::Harness::Parser::TAP::SubtestState;

use Time::HiRes qw/sleep/;

use base 'Test2::Harness::Parser';
use Test2::Util::HashBase qw/_subtest_state/;

sub init  { $_[0]->_init }
sub morph { $_[0]->_init }

sub _init {
    my $self = shift;
    $self->{+_SUBTEST_STATE} = Test2::Harness::Parser::TAP::SubtestState->new;
}

sub step {
    my $self = shift;

    my @events = ($self->parse_stdout, $self->parse_stderr);
    # If in_subtest is defined then the object is part of a buffered subtest
    # and therefore cannot be starting a streaming subtest.
    return map { defined $_->in_subtest ? $_ : $self->{+_SUBTEST_STATE}->maybe_start_streaming_subtest($_) } @events;
}

sub parse_stderr {
    my $self = shift;

    my $line = $self->proc->get_err_line(peek => 1) or return;

    return $self->slurp_comments('STDERR')
        if $line =~ m/^\s*#/;

    $line = $self->proc->get_err_line();
    chomp(my $out = $line);
    return unless length($out);
    return Test2::Event::UnknownStderr->new(output => $out);
}

sub parse_stdout {
    my $self = shift;

    my $line = $self->proc->get_out_line(peek => 1) or return;

    return $self->slurp_comments('STDOUT')
        if $line =~ m/^\s*#/;

    $line = $self->proc->get_out_line();
    my @events = $self->parse_tap_line($line);
    return @events if @events;

    chomp(my $out = $line);
    return unless length($out);
    return Test2::Event::UnknownStdout->new(output => $out);
}

sub parse_tap_line {
    my $self = shift;
    my ($line) = @_;

    chomp($line);
    my ($lead, $str) = ($line =~ m/^(\s+)(.+)$/) ? ($1, $2) : ('', $line);
    $lead =~ s/\t/    /g;
    my $nest = length($lead) / 4;

    my @events;
    # The buffered_subtest parsing always starts by trying to parse an "ok"
    # line, so we don't need to try parsing that _again_.
    my @types = qw/buffered_subtest plan bail version/;
    for my $type (@types) {
        my $sub = "parse_tap_$type";
        if (@events = $self->$sub($str, $nest)) {
            last;
        }
    }

    return @events;
}

sub parse_tap_buffered_subtest {
    my $self = shift;
    my ($line, $nest) = @_;

    my ($st_ok, @errors) = $self->parse_tap_ok($line, $nest) or return;
    return ($st_ok, @errors) unless $line =~ /\s*\{\s*\)?\s*$/;

    my $id = $self->{+_SUBTEST_STATE}->next_id;

    my @events;
    my @subevents;
    my $count = 0;
    while (1) {
        my $line = $self->proc->get_out_line();
        unless (defined $line) {
            sleep 0.1;
            die "Abrupt end to buffered subtest?" if $count++ > 10;
            next;
        }

        last if $line =~ m/^\s*\}\s*$/;
        my @e = $self->parse_tap_line($line);
        push @events => @e;
        # We might have events where in_subtest is already set in the case of
        # nested buffered subtests. In that case, we want those nested
        # subevents to _not_ be part of this particular subtest. Instead, they
        # are part of the child subtest contained in the parent. However, we
        # still want to emit _all_ the events as we see them, so we need to do
        # some filtering here.
        push @subevents => grep { !defined $_->in_subtest } @e;
    }

    $_->set_in_subtest($id) for @subevents;

    # If this is a buffered subtest marked as todo, then the "{" marking the
    # subtest ends up in the todo field instead of the name;
    my $todo = $st_ok->todo;
    $todo =~ s/\s*\{\s*$// if defined $todo;

    my $name = $st_ok->name;
    $name =~ s/\s*\{\s*$// if defined $name;

    my %st = (
        subtest_id => $id,
        name       => $name,
        pass       => $st_ok->pass,
        todo       => $todo,
        nested     => $nest,
        subevents  => \@subevents,
    );

    my $st = Test2::Event::Subtest->new(%st);

    return (@events, $st, @errors);
}

sub parse_tap_ok {
    my $self = shift;
    my ($line, $nest) = @_;

    my ($pass, $todo, $skip, $num, @errors);

    return unless $line =~ s/^(not )?ok\b//;
    $pass = !$1;

    push @errors => "'ok' is not immediately followed by a space."
        if $line && !($line =~ m/^ /);

    if ($line =~ s/^(\s*)(\d+)\b//) {
        my $space = $1;
        $num = $2;

        push @errors => "Extra space after 'ok'"
            if length($space) > 1;
    }

    # Not strictly compliant, but compliant with what Test-Simple does...
    # Standard does not have a todo & skip.
    if ($line =~ s/#\s*(todo & skip|todo|skip)(.*)$//i) {
        my ($directive, $reason) = ($1, $2);

        push @errors => "No space before the '#' for the '$directive' directive."
            unless $line =~ s/\s+$//;

        push @errors => "No space between '$directive' directive and reason."
            if $reason && !($reason =~ s/^\s+//);

        $skip = $reason if $directive =~ m/skip/i;
        $todo = $reason if $directive =~ m/todo/i;
    }

    # Standard says that everything after the ok (except the number) is part of
    # the name. Most things add a dash between them, and I am deviating from
    # standards by stripping it and surrounding whitespace.
    $line =~ s/\s*-\s*//;

    $line =~ s/^\s+//;
    $line =~ s/\s+$//;

    my $event;
    if ($line =~ /^Subtest: (.+)$/) {
        $event = Test2::Event::Subtest->new($self->{+_SUBTEST_STATE}->finish_streaming_subtest($pass, $line, $nest));
    }
    elsif (defined $skip) {
        $event = Test2::Event::Skip->new(
            reason => $skip,
            pass   => $pass,
            name   => $line,
            nested => $nest,
        );
    }
    else {
        $event = Test2::Event::Ok->new(
            defined($todo) ? (todo => $todo) : (),
            pass   => $pass,
            name   => $line,
            nested => $nest,
        );
    }

    return (
        $event,
        map { Test2::Event::ParseError->new(parse_error => $_) } @errors,
    );
}

sub parse_tap_version {
    my $self = shift;
    my ($line, $nest) = @_;

    return unless $line =~ s/^TAP version\s*//;

    return Test2::Event::TAP::Version->new(
        version => $line,
        nested  => $nest,
    );
}

sub parse_tap_plan {
    my $self = shift;
    my ($line, $nest) = @_;

    return unless $line =~ s/^1\.\.(\d+)//;
    my $max = $1;

    my ($directive, $reason);

    if ($max == 0) {
        if ($line =~ s/^\s*#\s*//) {
            if ($line =~ s/^(skip)\S*\s*//i) {
                $directive = uc($1);
                $reason = $line;
                $line = "";
            }
        }

        $directive ||= "SKIP";
        $reason    ||= "no reason given";
    }

    my $event = Test2::Event::Plan->new(
        max       => $max,
        directive => $directive,
        reason    => $reason,
        nested    => $nest,
    );

    return $event unless $line =~ m/\S/;

    return (
        $event,
        Test2::Event::ParseError->new(
            parse_error => 'Extra characters after plan.',
        ),
    );
}

sub parse_tap_bail {
    my $self = shift;
    my ($line, $nest) = @_;

    return unless $line =~ s/^Bail out! *//;

    return Test2::Event::Bail->new(
        reason => $line,
        nested => $nest,
    );
}

sub slurp_comments {
    my $self = shift;
    my ($io) = @_;

    my $meth = $io eq 'STDERR' ? 'get_err_line' : 'get_out_line';

    my $raw = $self->proc->$meth;
    my ($nest, $diag) = strip_comment($raw);

    die "Not a comment? ($raw)"
        unless defined($nest) && defined($diag);

    my $failed = $diag =~ m/^Failed test/ ? 1 : 0;

    while (1) {
        my $line = $self->proc->$meth(peek => 1) or last;
        my ($lnest, $msg) = strip_comment($line);
        last unless defined($lnest) && defined($msg);
        last if $lnest != $nest;
        last if $msg =~ m/^Failed test/;
        last if $failed && $msg !~ m/^at /;

        $raw .= $self->proc->$meth;

        $diag .= "\n$msg" if $msg;
        last if $failed;
    }

    my $class = $io eq 'STDERR' ? 'Test2::Event::Diag' : 'Test2::Event::Note';
    return $class->new(
        message => $diag,
        nested  => $nest,
    );
}

sub strip_comment {
    my $line = shift;
    chomp($line);
    my ($nest, $hash, $space, $msg) = split /(#)(\s*)/, $line, 2;
    return unless $msg || $hash || $space;

    $nest = length($nest) / 4;
    # We want to preserve any space in the comment _after_ the first space,
    # since proper TAP is formatted as "# $msg". So the first space is part of
    # the comment marker, while subsequent space is significant.
    $space =~ s/^ //;
    return ($nest, $space . $msg);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Parser::TAP - The TAP stream parser.

=head1 DESCRIPTION

This parser reads a TAP stream and converts it into L<Test2::Event>
objects. This parser can parse regular subtests as well as the new style
buffered subtests.

=head1 IMPORTANT NOTE ON PARSING OF STREAMING SUBTESTS

This will parse streaming subtests and turn them into events, however it may
not report the proper nesting of the subtests. Streaming subtest nesting is
reconstructed once the subtest finishes. This is important because the parser
cannot be sure of nesting until the outer-most subtest has completed. Example:

            ok 1 - I am nested, but how deep?
                ok 1 - I am nested, but how deep?
            ok 2
            1..2
        ok 1 - That subtest ended
    ok 1 - Outer subtest ended

Looking at this a human can say "Oh, each subtest has a 4 space indentation"
but the parser has to read it 1 line at a time, and sends each line as a event
before processing the next line. The event is first sent to the renderer as an
orphan, the render can choose to display it, erase it or ignore it. Once the
outer-most subtest ends the job is able to determine the correct nesting and
sends a L<Test2::Event::Subtest> containing the full nested subtest structure
reconstructed. This allows a render to display a progress indicator that
updates for all events generated inside the subtest, which it can then replace
with the full subtest rendered at the end.

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
