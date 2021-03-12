package Test2::Harness::UI::Controller::Events;
use strict;
use warnings;

our $VERSION = '0.000046';

use Data::GUID;
use List::Util qw/max/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Events' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);
    my $user = $req->user;
    my $schema = $self->{+CONFIG}->schema;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{id} or die error(404 => 'No name or id');

    my $p = $req->parameters;
    my (%query, %attrs, $rs, $meth);

    $attrs{order_by} = {-asc => 'event_ord'};

    if ($route->{from} eq 'job') {
        my $job_key = $it;
        my $job = $schema->resultset('Job')->find({job_key => $job_key})
            or die error(404 => 'Invalid Job');

        $query{job_key} = $job_key;

        $meth = 'line_data';

        unless ($job->complete || $p->{load_subtests}) {
            my @events;
            my $flush = 0;
            my $offset = 0;
            my $nested_offset = 0;

            $res->stream(
                env          => $req->env,
                content_type => 'application/x-jsonl; charset=utf-8',

                done => sub {
                    return 0 if @events;

                    unless ($flush) {
                        $job->discard_changes;
                        return 0;
                    }

                    return $job->complete;
                },
                fetch => sub {
                    $flush = 1 if $job->complete;

                    # Get main events
                    my @new = $schema->resultset('Event')->search(
                        {%query, nested => 0, event_ord => {'>', $offset}},
                        \%attrs,
                    )->all;

                    if (@new) {
                        $offset = $new[-1]->event_ord;
                        push @events => @new;
                    }

                    unless (@events) {
                        # Fallback to an orphan for progress
                        my $nest = $schema->resultset('Event')->search(
                            {%query, nested => 1, event_ord => {'>', max($offset, $nested_offset)}},
                            {order_by => {-desc => 'event_ord'}, limit => 1},
                        )->first;

                        if ($nest) {
                            $nested_offset = $nest->event_ord;
                            push @events => $nest;
                        }
                    }

                    return unless @events;
                    return encode_json(shift(@events)->$meth) . "\n";
                },

            );

            return $res;
        }

        $query{parent_id} = undef unless $p->{load_subtests} && lc($p->{load_subtests}) ne 'false';
        $rs = $schema->resultset('Event')->search(\%query, \%attrs);
    }
    elsif ($route->{from} eq 'single_event') {
        my $event_id = $it;

        my $event = $schema->resultset('Event')->find({event_id => $event_id})
            or die error(404 => 'Invalid Event');

        $res->content_type('application/json');
        $res->raw_body($event);
        return $res;
    }
    elsif ($route->{from} eq 'event') {
        my $event_id = $it;

        my $event = $schema->resultset('Event')->find({event_id => $event_id})
            or die error(404 => 'Invalid Event');

        if ($p->{load_subtests}) {
            # If we are loading subtests then we want ALL descendants, so here
            # we take the parent event and find the next event of the same
            # nesting level, then we want all events with an event_ord between
            # them (in the same job);
            my $end_at = $schema->resultset('Event')->find(
                {%query, nested => $event->nested, event_ord => {'>' => $event->event_ord}},
                {%attrs},
            );

            $query{event_ord} = {'>' => $event->event_ord, '<' => $end_at->event_ord};
        }
        else {
            # We want direct descendants only
            $query{'parent_id'} = $event_id;
        }

        $meth = 'st_line_data';
        $rs = $schema->resultset('Event')->search(\%query, \%attrs);
    }
    else {
        die error(501);
    }

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        resultset    => $rs,
        data_method  => $meth,
    );

    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Events

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
