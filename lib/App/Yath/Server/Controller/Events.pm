package App::Yath::Server::Controller::Events;
use strict;
use warnings;

our $VERSION = '2.000005';

use List::Util qw/max/;
use App::Yath::Server::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;


use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase;

sub title { 'Events' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req    = $self->{+REQUEST};
    my $res    = resp(200);
    my $user   = $req->user;
    my $schema = $self->schema;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{id} or die error(404 => 'No name or id');

    my $p = $req->parameters;
    my (%query, %attrs, $rs, $meth, $event);

    if ($route->{from} eq 'single_event') {
        $event = $schema->resultset('Event')->find_by_id_or_uuid($it, {remove_columns => [qw/orphan/]})
            or die error(404 => 'Invalid Event');
    }
    else {
        $event = $schema->resultset('Event')->find_by_id_or_uuid($it, {remove_columns => [qw/orphan facets/]})
            or die error(404 => 'Invalid Event');
    }

    $attrs{order_by} = {-asc => ['event_idx', 'event_sdx', 'event_id']};

    if ($route->{from} eq 'single_event') {
        $res->content_type('application/json');
        $res->raw_body($event);
        return $res;
    }

    if ($p->{load_subtests}) {
        $query{job_try_id} = $event->job_try_id;           # Same job try
        $query{event_idx} = $event->event_idx;             # Same subtest
        $query{event_id}  = {'!=' => $event->event_id};    # Not this event
    }
    else {
        # We want direct descendants only
        $query{'parent_id'} = $event->event_id;
    }

    $rs = $schema->resultset('Event')->search(
        \%query,
        \%attrs
    );

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        resultset    => $rs,
        data_method  => 'st_line_data',
    );

    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::Events - Controller for fetching events

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT

