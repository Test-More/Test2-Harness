package Test2::Harness::Event;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/confess croak/;
use List::Util qw/first/;
use Scalar::Util qw/reftype/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use constant EFLAG_TERMINATOR => 1;   # Not a real event
use constant EFLAG_SUMMARY    => 2;   # Contains a final summary of a job
use constant EFLAG_HARNESS    => 4;   # Contains harness_*
use constant EFLAG_ASSERT     => 8;   # Contains an assertion
use constant EFLAG_EMINENT    => 16;  # Contains critical info that may cause or explain failures
use constant EFLAG_STATE      => 32;  # Things that effect state, plans, asserts, etc
use constant EFLAG_PEEK       => 64;  # Early look at events that will be seen inside subtests later
use constant EFLAG_COVERAGE   => 128; # Coverage data

my %FLAGMAP = map {my $c = "EFLAG_$_"; $_ => __PACKAGE__->$c()} qw/TERMINATOR SUMMARY HARNESS ASSERT EMINENT STATE PEEK COVERAGE/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{ EFLAG_TERMINATOR EFLAG_SUMMARY EFLAG_HARNESS EFLAG_ASSERT EFLAG_EMINENT EFLAG_STATE EFLAG_PEEK EFLAG_COVERAGE };

use Test2::Harness::Util::HashBase qw{
    +json
    +facet_data
    +flags
};

my @REQUIRED_HARNESS_FIELDS = qw{
    stamp
    run_id
    job_id
    job_try
    event_id
    from_stream
};

sub trace { $_[0]->facet_data->{trace} }

sub init {
    my $self = shift;

    return if $self->{+JSON} && !$self->{+FACET_DATA};

    $self->_verify();
}

sub facet_data {
    my $self = shift;

    return $self->{+FACET_DATA} if exists $self->{+FACET_DATA};
    return $self->expand if $self->{+JSON} && !$self->{+FACET_DATA};
    return undef;
}

sub expand {
    my $self = shift;

    confess "'facet_data' is already populated" if $self->{+FACET_DATA};

    my $json = $self->{+JSON} or confess "No JSON data to expand";
    my $facet_data = decode_json($json);

    return $self->{+FACET_DATA} = $facet_data;
}

sub dirty {
    my $self = shift;
    $self->expand if $self->{+JSON} && !$self->{+FACET_DATA};
    delete $self->{+JSON};
    return;
}

sub _verify {
    my $self = shift;

    $self->expand if $self->{+JSON} && !$self->{+FACET_DATA};

    my $data = $self->{+FACET_DATA} || confess "'facet_data' is a required attribute";

    confess "'facet_data' contains nested facet_data" if $data->{facet_data};

    for my $field (@REQUIRED_HARNESS_FIELDS) {
        confess "'{harness}->{$field}' is a required attribute" unless defined $data->{harness}->{$field};
    }

    return;
}

for (@REQUIRED_HARNESS_FIELDS) {
    my $field = $_;

    my $sub = sub { shift->facet_data->{harness}->{$field} };
    no strict 'refs';
    *$field = $sub;
}

sub has_flag {
    my $self = shift;
    my ($flag) = @_;

    my $fbit = $FLAGMAP{uc($flag)} // croak "Invalid flag: '$flag'";

    my $flags = $self->flags;

    return $flags & $flag;
}

sub flags {
    my $self = shift;
    return $self->{+FLAGS} if exists $self->{+FLAGS} && !$self->{+FACET_DATA};
    return $self->facet_data->{harness}->{+FLAGS} //= $self->{+FLAGS} // $self->_calculate_flags;
}

sub _calculate_flags {
    my $self = shift;
    my $fd   = $self->facet_data;

    my $flags = 0;

    $flags |= EFLAG_PEEK     if $fd->{harness}->{buffered};
    $flags |= EFLAG_SUMMARY  if exists $fd->{harness_job_end};
    $flags |= EFLAG_STATE    if exists $fd->{plan};
    $flags |= EFLAG_COVERAGE if exists $fd->{coverage};
    $flags |= EFLAG_EMINENT  if exists($fd->{info}) && first { $_->{debug} || $_->{important} || lc($_->{tag}) eq 'STDERR' } @{$fd->{info}};

    $flags |= EFLAG_HARNESS if first { m/^harness_/ } keys %$fd;

    $flags |= EFLAG_EMINENT | EFLAG_STATE if exists($fd->{control}) && ($fd->{control}->{terminate} || $fd->{control}->{halt});

    if (exists($fd->{errors}) && @{$fd->{errors}}) {
        $flags |= EFLAG_EMINENT;
        $flags |= EFLAG_STATE if first { $_->{fail} } @{$fd->{errors}};
    }

    if (my $assert = $fd->{assert}) {
        $flags |= EFLAG_STATE;
        $flags |= EFLAG_EMINENT unless $assert->{pass} || $fd->{amnesty} && @{$fd->{amnesty}};
    }

    return $flags;
}

sub as_json { $_[0]->{+JSON} //= encode_json($_[0]) }

sub TO_JSON {
    my $self = shift;

    my $fd = $self->facet_data;
    $fd->{harness}->{+FLAGS} //= $self->{+FLAGS} // $self->_calculate_flags();

    $self->_prune($fd);

    return $fd;
}

sub prune {
    my $self = shift;
    my ($fd) = @_;

    $fd //= $self->facet_data;

    $self->_prune($fd);
}

sub _prune {
    my $self = shift;
    my ($fd) = @_;

    if (my $p = $fd->{parent}) {
        if (my $children = $p->{children}) {
            $self->_prune($_) for @$children;
        }
    }

    if (my $t = $fd->{trace}) {
        delete $t->{full_call};
        delete $t->{full_caller};

        if ($fd->{hubs} && @{$fd->{hubs}}) {
            delete $t->{hid};
            delete $t->{huuid};
            delete $t->{nested};
            delete $t->{buffered};
        }
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Event - A harness-specific representation of a Test2 event.

=head1 DESCRIPTION

Test2 tests produce a sequence of events objects L<Test2::Event>. This is an
independant representation of those events for use in L<Test2::Harness>. Even
non-test2 tests which produce TAP output will have the output parsed into these
types of events.

=head1 SYNOPSIS

In normal usage you will never need to create one of these events yourself.
This documentation assumes you are operating on an existing event C<$event>
that the harness exposed to you via a plugin or similar.

    my $facet_data = $event->facet_data;
    my $run_id     = $event->run_id;
    my $job_id     = $event->job_id;
    my $job_try    = $event->job_try;
    my $event_id   = $event->event_id;

=head1 METHODS

=over 4

=item $event->expand

Sometimes an event is created with the data locked up in a JSON string that has
not been decoded yet. This method will expand that data into the facet_data.

B<NOTE:> This method will throw an exception if the data is already expanded,
if the C<facet_data> is already present, or if there is no JSON data to expand.

B<NOTE:> Other methods will call C<expand()> if/when they need to. Only call
this yourself if you intended to bypass methods and access the event data
directly.

=item $event->dirty

If you are planning to modify the event, or have already done so, you should
call this to clear the cached copy of the json data. If you fail to call this
none of your changes will show up if the event gets serialized to json again.

=item $bool = $event->has_flag($FLAG)

=item $bits = $event->flags

These are used to get/check the event flags. Flags are meta-data about events
that can tell you what type of info the event conveys without actually needing
to look at the event.

This is mainly useful for renderers which can choose to skip or render an event
based on flags. Using flags when possible can improve performance as flags are
transmitted between processes seperate from the json data, if everything simply
checks the flags and ignores unnecessary events those events may never even be
decoded from json.

In other words, flags make it easy to skip "noise" events you might not care
about.  This can even be used to avoid deserializing the event from JSON if
nothing cares about the content.

You can import these constants from L<Test2::Harness::Util::Constants>.

B<NOTE>: when using C<< $e->has_flag($FLAG) >> $FLAG must be a string like
'terminator', the 'EFLAG_' prefix must not be included.

=over 4

=item EFLAG_TERMINATOR or 'terminator'

This is set when the event is not actually an event, but rather the json 'null'
indicating the end of the event stream. DO NOT try to use an event with this
flag set. Generally only the harness itself will see these, so renderers and
plugins can assume they will never see it. If a renderer or plugin gets an
event with the 'terminator' flag set that would be a bug in the harness.

=item EFLAG_SUMMARY or 'summary'

This is set if the event contains a final job summary, also known as the
'harness_job_end' facet.

=item EFLAG_HARNESS or 'harness'

This is set for any event with a facet matching C< m/^harness_/ >. Events with
harness_ facets usually have essential information such as job start and end.

=item EFLAG_ASSERT or 'assert'

Any event which has an assertion has this flag set. Assertions are the bread
and butter of testing so they get their own flag.

=item EFLAG_EMINENT or 'eminent'

This is set if the event contains eminent info such as a failing test, and
error, diagnostcis, prints to STDERR. In short nearly all renderers will
absolutely want to show this event. This WILL be set for any event that causes
a failure. It is also USUALLY set for events that explain a failure.

=item EFLAG_STATE or 'state'

This is set if the event modifies state in any way. Assertions, plans,
fatal errors, etc.

=item EFLAG_PEEK or 'peek'

This is set if the event is "Buffered" which means the event belongs in a
subtest and will be seen again later inside that subtest. These are essentially
orphaned or ephemeral events that can be ignored, however some renderers may
like to display them to indicate a running subtest that has not completed yet.
The actual final form of the event will come later though nested inside a
subtest event.

=item EFLAG_COVERAGE or 'coverage'

This is set if the event contains a 'coverage' facet. These are typically
produced by L<Test2::Plugin::Cover>. These get a special flag because the
harness and several plugins may want to process coverage events, without this
flag all events would need to be decoded to find this info.

=back

=item $hashref = $event->TO_JSON

Used for json serialization.

=item $json_string = $event->as_json

This will return a json representation of the event. Note that this is a lossy
conversion with some harness specific state removed by design. This may even be
a cached copy of the json string that was decoded to produce the original
object. If the string was not cached before it will be cached for all future
calls ignoring any state change to the event.

The lossy/cached conversion is intended so that events get passed through the
harness pipeline without modifications from one step translating to another. If
you need something extra to go through you need to either replace the event or
create an additional one.

=item $string = $event->event_id

Usually a UUID, but not always!

=item $hashref = $event->facet_data

Get the event facet data, this is the meat of the event that hold all the
state.

=item $string = $event->job_id

Usually a UUID, but not always!

=item $int = $event->job_try

Integer, 0 or greater. Some jobs are run additional times if they fail, this
says which attempt the event is for. The counter starts at 0.

=item $string = $event->run_id

The run id. This is usually a UUID, but not always!

=item $ts = $event->stamp

A unix timestamp for when the event was created.

=item $trace = $event->trace

This is a shortcut for C<< $event->facet_data->{trace} >>. The trace data is
essential and used everywhere.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
