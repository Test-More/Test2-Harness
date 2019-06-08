package Test2::Harness::UI::Controller::Events;
use strict;
use warnings;

our $VERSION = '0.000003';

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
    my (%query, %attrs, $rs);

    $attrs{order_by} = {-asc => ['event_ord', 'event_id']};

    if ($route->{from} eq 'job') {
        my $job_id = $it;
        my $job = $schema->resultset('Job')->find({job_id => $job_id})
            or die error(404 => 'Invalid Job');

        $query{job_id} = $job_id;
        $query{parent_id} = undef unless $p->{load_subtests} && lc($p->{load_subtests}) ne 'false';

        $rs = $schema->resultset('Event')->search(\%query, \%attrs);
    }
    elsif ($route->{from} eq 'event') {
        my $event_id = $it;

        my $event = $schema->resultset('Event')->find({event_id => $event_id})
            or die error(404 => 'Invalid Event');

        $query{job_id} = $event->job_id;

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

        $rs = $schema->resultset('Event')->search(\%query, \%attrs);
    }
    else {
        die error(501);
    }

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        resultset    => $rs,
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
