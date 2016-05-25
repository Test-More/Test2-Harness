package Test2::Harness::Parser::TAP;
use strict;
use warnings;

our $VERSION = '0.000003';

use Test2::Harness::Fact;

use base 'Test2::Harness::Parser';
use Test2::Util::HashBase qw/subtests sid last_nest/;

sub morph {
    my $self = shift;
    $self->{+SUBTESTS} = [];
    $self->{+SID} = 'A';
    $self->{+LAST_NEST} = 0;
}

sub parse_tap_line {
    my $self = shift;
    my ($line) = @_;

    chomp($line);
    my ($nest, $str) = ($line =~ m/^(\s+)(.+)$/) ? ($1, $2) : ('', $line);
    $nest =~ s/\t/    /g;
    $nest = length($nest) / 4;

    my @types = qw/buffered_subtest ok plan bail version/;

    my @facts;
    for my $type (@types) {
        my $sub = "parse_tap_$type";
        @facts = $self->$sub($str);
        last if @facts;
    }

    return unless @facts;

    for my $f (@facts) {
        $f->set_parsed_from_string($line)    unless defined $f->parsed_from_string;
        $f->set_parsed_from_handle('STDOUT') unless defined $f->parsed_from_handle;
        $f->set_nested($nest)                unless defined $f->nested;

        $self->adjust_subtests($f);
    }

    return @facts;
}

sub parse_tap_buffered_subtest {
    my $self = shift;
    my ($line) = @_;

    my ($st_ok, @errors) = $self->parse_tap_ok($line) or return;
    my $summary = $st_ok->summary;
    return ($st_ok, @errors) unless $summary =~ s/\s*\{\s*$//;
    $st_ok->set_summary($summary);

    my @subevents;
    while (1) {
        my $line = $self->proc->get_out_line() or die "Abrupt end to buffered subtest?";

        last if $line =~ m/^\s*\}\s*$/;
        push @subevents => $self->parse_tap_line($line);
    }

    return (@subevents, $st_ok, @errors);
}

sub parse_tap_version {
    my $self = shift;
    my ($line) = @_;

    return unless $line =~ s/^TAP version\s*//;

    return Test2::Harness::Fact->new(
        event   => 1,
        output  => $line,
        summary => "Producer is using TAP version $line.",
    );
}

sub parse_tap_plan {
    my $self = shift;
    my ($line) = @_;

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

    my $summary;
    if ($max || !$directive) {
        $summary = "Plan is $max assertions";
    }
    elsif($reason) {
        $summary = "Plan is '$directive', $reason";
    }
    else {
        $summary = "Plan is '$directive'";
    }

    my $fact = Test2::Harness::Fact->new(
        event     => 1,
        summary   => $summary,
        sets_plan => [$max, $directive, $reason],
    );

    return $fact unless $line =~ m/\S/;

    return(
        $fact,
        Test2::Harness::Fact->new(parse_error => "Extra characters after plan."),
    );
}

sub parse_tap_bail {
    my $self = shift;
    my ($line) = @_;

    return unless $line =~ m/^Bail out!/;

    return Test2::Harness::Fact->new(
        event       => 1,
        summary     => $line,
        terminate   => 255,
        causes_fail => 1,
    );
}

sub parse_tap_ok {
    my $self = shift;
    my ($line) = @_;

    my ($pass, $todo, $skip, $num, @errors);

    return unless $line =~ s/^(not )?ok\b//;
    $pass = !$1;

    push @errors => "'ok' is not immedietly followed by a space."
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
    my $summary = $line || "Nameless Assertion";
    my $effective_pass = $pass || 0;

    if ($todo) {
        $summary .= " (TODO: $todo)";
        $effective_pass = 1;
    }
    elsif(defined $todo) {
        $summary .= " (TODO)";
        $effective_pass = 1;
    }

    if ($skip) {
        $summary .= " (SKIP: $skip)";
    }
    elsif(defined $skip) {
        $summary .= " (SKIP)";
    }

    my $fact = Test2::Harness::Fact->new(
        event => {
            defined($skip) ? (reason => $skip) : (),
            defined($todo) ? (todo   => $todo) : (),
            pass           => $pass,
            effective_pass => $effective_pass,
        },

        summary          => $summary,
        number           => $num,
        increments_count => 1,
        causes_fail      => ($effective_pass) ? 0 : 1,
    );

    return $fact unless @errors;

    return (
        $fact,
        map { Test2::Harness::Fact->new(parse_error => $_) } @errors,
    );
}

sub step {
    my $self = shift;

    my @facts;
    push @facts => $self->parse_stdout;
    push @facts => $self->parse_stderr;
    return @facts;
}

sub parse_stderr {
    my ($self) = @_;

    my $line = $self->proc->get_err_line(peek => 1) or return;

    return $self->slurp_comments('STDERR')
        if $line =~ m/^\s*#/;

    $line = $self->proc->get_err_line();
    chomp(my $out = $line);
    return unless length($out);
    return Test2::Harness::Fact->new(
        nested             => 0,
        output             => $out,
        parsed_from_handle => 'STDERR',
        parsed_from_string => $line,
        diagnostics        => 1,
    );
}

sub parse_stdout {
    my ($self) = @_;

    my $line = $self->proc->get_out_line(peek => 1) or return;

    if ($line =~ m/^\s*#/) {
        my $f = $self->slurp_comments('STDOUT');
        $self->adjust_subtests($f);
        return $f;
    }

    $line = $self->proc->get_out_line();
    my @facts = $self->parse_tap_line($line);
    return @facts if @facts;

    chomp(my $out = $line);
    return unless length($out);
    return Test2::Harness::Fact->new(
        output             => $out,
        parsed_from_handle => 'STDOUT',
        parsed_from_string => $line,
        diagnostics        => 0,
    );
}

sub strip_comment {
    my $line = shift;
    chomp($line);
    my ($nest, $hash, $space, $msg) = split /(#)(\s*)/, $line, 2;
    return unless $msg || $hash || $space;

    $nest = length($nest) / 4;

    return ($nest, $msg);
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

    return Test2::Harness::Fact->new(
        event              => 1,
        nested             => $nest,
        summary            => $diag,
        parsed_from_string => $raw,
        parsed_from_handle => $io,
        diagnostics        => $io eq 'STDERR' ? 1 : 0,
        hide               => $diag ? 0 : 1,
    );
}

sub adjust_subtests {
    my $self = shift;
    my ($f) = @_;

    my $n        = $f->nested;
    my $last     = $self->{+LAST_NEST} || 0;
    my $subtests = $self->{+SUBTESTS};

    if ($n < $last) {
        $f->set_is_subtest($subtests->[$last]);
        $subtests->[$last] = undef;
    }

    if ($n) {
        my $stid = $subtests->[$n] ||= $self->{+SID}++;
        $f->set_in_subtest($stid);
    }

    $self->{+LAST_NEST} = $n;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Parser::TAP - The TAP stream parser.

=head1 DESCRIPTION

This parser reads a TAP stream and converts it into L<Test2::Harness::Fact>
objects. This parser can parse regular subtests as well as the new style
buffered subtests.

=head1 IMPORTANT NOTE ON SUBTEST PARSING

This will parse subtests and turn them into facts, however it may not report
the proper nesting of the subtests. Subtest nesting is reconstructed by the
L<Test2::Harness::Job> object. This is important because the parser cannot be
sure of nesting until the outer-most subtest has completed. Example:

            ok 1 - I am nested, but how deep?
                ok 1 - I am nested, but how deep?
            ok 2
            1..2
        ok 1 - That subtest ended
    ok 1 - Outer subtest ended

Looking at this a human can say "Oh, each subtest has a 4 space indentation"
but the parser has to read it 1 line at a time, and sends each line as a fact
before processing the next line. The fact is first sent to the renderer as an
orphan, the render can choose to displayit, erase it or ignore it. Once the
outer-most subtest ends the job is able to determine the correct nesting and
sends a fact containing an L<Test2::Harness::Result> object with the full
nested subtest structure reconstructed. This allows a render to display a
progress indicator that updates for all facts generated inside the subtest,
which it can then replace with the full subtest rendered at the end.

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
