package Test2::Harness::Fact;
use strict;
use warnings;

our $VERSION = "0.000001";

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util qw/pkg_to_file/;
use Scalar::Util qw/blessed/;

BEGIN {
    my $ok = eval {
        require JSON::MaybeXS;
        JSON::MaybeXS->import('JSON');
        1;
    };

    unless($ok) {
        require JSON::PP;
        *JSON = sub { 'JSON::PP' };
    }
}

use Test2::Util::HashBase qw{
    stamp
    _summary
    nested

    diagnostics
    causes_fail
    increments_count
    sets_plan
    in_subtest
    is_subtest
    terminate
    number

    hide
    start
    event
    result
    parse_error
    output
    encoding
    parser_select

    parsed_from_string
    parsed_from_handle
};

sub init {
    my $self = shift;

    $self->{+STAMP} ||= time;
    $self->{+_SUMMARY} = delete $self->{summary} if $self->{summary};
}

*set_summary = \&set__summary;
sub summary {
    my $self = shift;
    return $self->{+_SUMMARY}      if defined $self->{+_SUMMARY};
    return $self->{+START}         if defined $self->{+START};
    return $self->{+PARSE_ERROR}   if defined $self->{+PARSE_ERROR};
    return $self->{+PARSER_SELECT} if defined $self->{+PARSER_SELECT};
    return $self->{+OUTPUT}        if defined $self->{+OUTPUT};
    return $self->{+RESULT}->name  if defined $self->{+RESULT};
    return $self->{+ENCODING}      if defined $self->{+ENCODING};
    return "no summary";
}

sub TO_JSON {
    my $self = shift;
    my $pkg = blessed($self);
    return { %$self, __PACKAGE__ => $pkg };
}

sub to_json {
    my $self = shift;

    my $J = JSON->new;
    $J->indent(0);
#    $J->canonical(1);
    $J->convert_blessed(1);

    return $J->encode($self);
}

sub from_string {
    my $class = shift;
    my ($string, %override) = @_;
    my $json = $string;
    return unless $json =~ s/^T2_EVENT:\s//;
    return $class->from_json($json, parsed_from_string => $string, %override);
}

sub from_json {
    my $class = shift;
    my ($json, %override) = @_;

    my $data = eval { JSON->new->decode($json) };
    my $err = $@;

    if ($data) {
        my $pkg = delete $data->{__PACKAGE__} || $class;
        my $self = $pkg->new(%$data, %override);
        return $self;
    }

    chomp($err);
    return $class->new(
        summary     => $err,
        parse_error => $err,
        causes_fail => 1,
        diagnostics => 1,
    );
}

sub from_event {
    my $class = shift;
    my ($event, %override) = @_;

    my $epkg  = blessed($event);
    my $efile = $INC{pkg_to_file($epkg)};
    my $trace = $event->trace;

    my @plan = $event->sets_plan;

    my $event_data = {
        '__PACKAGE__' => $epkg,
        '__FILE__'    => $efile,

        %$event,

        $trace ? (trace => {%{$trace}, __PACKAGE__ => blessed($trace)}) : (),
    };

    my %attrs = (
        EVENT() => $event_data,

        _SUMMARY()         => $event->summary          || "[no summary]",
        CAUSES_FAIL()      => $event->causes_fail      || 0,
        INCREMENTS_COUNT() => $event->increments_count || 0,
        NESTED()           => $event->nested           || 0,
        HIDE()             => $event->no_display       || 0,
        DIAGNOSTICS()      => $event->diagnostics      || 0,
        IN_SUBTEST()       => $event->in_subtest       || undef,
        TERMINATE()        => $event->terminate        || undef,

        SETS_PLAN() => @plan ? \@plan : undef,
        IS_SUBTEST() => $event->can('subtest_id') ? $event->subtest_id || undef : undef,
    );

    return $class->new(%attrs, %override);
}

sub from_result {
    my $class = shift;
    my ($result, %override) = @_;

    my %attrs = (
        RESULT() => $result,

        NESTED()      => ($result->nested || 0) - 1,
        IN_SUBTEST()  => $result->in_subtest || undef,
        IS_SUBTEST()  => $result->is_subtest || undef,

        CAUSES_FAIL() => $result->passed ? 0 : 1,
    );

    return $class->new(%attrs, %override);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Fact - Representation of an event or output line from a test.

=head1 DESCRIPTION

Test2 generates events. Events are encapsulated by L<Test2::Event> objects.
Unfortunately a harness must be able to handle output beyond what the events
handle. A fact is an abstraction of an even or line of output from the test.
This includes data such as what filehandle it came from, what the output line
that generated it looked like, etc.

Some producers are able to send entire L<Test2::Event> objects, in which case
the original object can be retrieved from the fact.

=head1 ATTRIBUTES

All of these can be provided as construction arguments. You can also call
C<set_ATTR(...)> for any attribute to set a value.

=over 4

=item $ts = $f->stamp

Timestamp from fact creation.

=item $summary = $f->summary

A human-readable summary of the event. If this is not provided one will be
generated.

=item $int = $f->nested

This will be an integer representing how deeply nested a fact is (IE subtests).

This will be -1 for the fact containing the final L<Test2::Harness::Result>
object. It will be 0 for any root-level event or subtest. This will be 1 for
events inside a subtest, 2 for a nested subtest, etc.

It is also valid for this to be undefined, in which case it should be treated
as a 0.

=item $bool = $f->diagnostics

True if the event should be displayed even in non-verbose mode for diagnostics
purposes.

=item $bool = $f->causes_fail

True if the fact results in a failure. (Example: 'not ok')

=item $bool = $f->increments_count

True if the fact adds to the test count.

=item $plan_ref = $f->sets_plan()

This will be undefined unless the fact sets the plan. The plan is returned as a 3 element array:

    [$expected_test_count, $directive, $reason]

C<$directive> and C<$reason> are typically undefined, but will be present in
cases such as skip-all.

=item $id = $f->in_subtest()

If the fact is inside a subtest then this will have a unique identifier for
the subtest. The unique identifier is arbitrary and parser specific.

=item $id = $f->is_subtest()

If the fact is a final subtest result this will contain a unqiue identifier for
it. The unique identifier is arbitrary and parser specific.

=item $code = $f->terminate()

If the fact resulted in the test file terminating then this will be populated
with an integer exit value.

=item $int = $f->number()

If the fact incremented the test count this will have the test number. For
other facts this will either contain the last test number seen, or it will be
undefined.

=item $bool = $f->hide()

True if the renderers should hide the event. (This is for IPC events not
intended for humans to see).

=item $bool = $f->start()

This is true if the fact represents the test file being started.

=item $e = $f->event

This is true if the fact was I<likely> created because of an L<Test2::Event>
object. Depending on the parser this could be a simple boolean, or it could be
a fully reconstructed L<Test2::Event> object, or a hash of fields from the
event object.

True/False is the only part of the return you can trust to always be available.

=item $error = $f->parse_error

This will be set to the error string if the fact is the result of a parser
error.

=item $text = $f->output

This will be set if the fact was produced directyl from a line of STDERR or
STDOUT.

=item $enc = $f->encoding

Set if this fact is intended to set the encoding.

=item $f->parser_select

This will be set to the name of the parser upon parser selection.

=item $line = $f->parsed_from_string

If the fact was produced from a line of output the original line will be here.

=item $name = $f->parsed_from_handle

This will typically return 'STDERR' or 'STDOUT'. This can be undefined if the
fact was not produced from a line of output.

=back

=head1 METHODS

=over 4

=item $json = $f->to_json

Convert the fact to JSON.

=item $f = Test2::Harness::Fact->from_string($str, %overrides)

Construct a fact from a string:

    T2_EVENT: ...JSON DATA...

=item $f = Test2::Harness::Fact->from_json($json, %overrides)

Construct an event from JSON data.

=item $f = Test2::Harness::Fact->from_event($event, %overrides)

Construct a fact from an L<Test2::Event> object.

=item $f = Test2::Harness::Fact->from_result($result, %overrides)

Construct a fact from an L<Test2::Harness::Result> object.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
