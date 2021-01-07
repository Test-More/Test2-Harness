package Test2::Harness::Event;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/confess croak/;
use List::Util qw/first/;
use Scalar::Util qw/reftype/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use constant TERMINATOR => 0;    # NULL terminator
use constant SUMMARY    => 1;    # Final State
use constant STATUS     => 2;    # Process start/stop times
use constant EMINENT    => 3;    # STDERR, Failures, etc, exit-false
use constant STATE      => 4;    # Passing Assertions, exit-true, things that effect state
use constant INFO       => 5;    # Any other messages
use constant PEEK       => 6;    # Early look at events that will be seen inside subtests later

use Importer Importer => 'import';

our @EXPORT_OK = qw{ TERMINATOR SUMMARY STATUS EMINENT STATE INFO };

use Test2::Harness::Util::HashBase qw{
    +json
    +facet_data
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

sub level {
    my $self = shift;
    return $self->facet_data->{harness}->{level} //= $self->_calculate_level;
}

sub set_level {
    my $self = shift;
    my ($set) = @_;

    croak "You cannot clear the level" unless @_;
    croak "You cannot set an undefined level" unless defined $set;

    {
        no warnings 'numeric';
        my $int = int($set);
        croak "Level must be an integer (got $set)" unless $set == $int && "$set" eq "$int";
    }

    my $level = $self->level;
    croak "You cannot increase the level value (from $level to $set), you can only lower it" if $set > $self->level;
    croak "You cannot set a level lower than 1 (attempted $set)" if $set < 1;

    $self->{harness}->{level} = $set;
}

sub _calculate_level {
    my $self = shift;
    my $fd = $self->facet_data;

    return PEEK if $fd->{harness}->{buffered};

    return SUMMARY if exists $fd->{harness_job_end};

    for my $f (keys %$fd) {
        return STATUS if $f =~ m/^harness_/; # Any event with a harness_ is STATUS level or lower
    }

    return EMINENT if exists($fd->{errors}) && @{$fd->{errors}};
    return EMINENT if exists($fd->{info}) && first { $_->{debug} || $_->{important} || lc($_->{tag}) eq 'STDERR' } @{$fd->{info}};
    return EMINENT if exists($fd->{control}) && ($fd->{control}->{terminate} || $fd->{control}->{halt});

    if (exists $fd->{assert}) {
        my $assert = $fd->{assert};
        return EMINENT unless $assert->{pass} || $fd->{amnesty} && @{$fd->{amnesty}};
        return STATE;
    }

    return STATE if exists $fd->{plan};

    # Everything else
    return INFO;
}

sub as_json { $_[0]->{+JSON} //= encode_json($_[0]) }

sub TO_JSON {
    my $self = shift;

    my $fd = $self->facet_data;
    $fd->{harness}->{level} //= $self->_calculate_level();

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

=item $int = $event->level

This will tell you what 'level' the event is. This is mainly useful to
renderers as it makes it easy to skip "noise" events you might not care about.
This can even be used to avoid deserializing the event from JSON if nothing
cares about the content.

You can import these constants from L<Test2::Harness::Util::Constants>.

B<NOTE:> The level indicates the lowest level the event carries, it may also
contain data that on its own would be at a higher level.

=over 4

=item TERMINATOR => 0

This is used to indicate a NULL terminator... You should never actually see an
event of this level as it is for internal-use only.

=item SUMMARY => 1

This indicates that the event contains a final summary of an entire test job or
run.

=item STATUS => 2

This indicates that the event contains job status events such as job start, job
end, etc.

=item EMINENT => 3

This indicates the event contains important information such as a failed
assertion, diagnostics, STDERR output, etc.

=item STATE => 4

This indicates that the event produces a state change, such as a passing
assertion, a plan, etc.

=item INFO => 5

This is the catch-all for everything else. This includes prints to STDOUT,
NOTE's, and other things that are typically only shown in verbose mode.

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
