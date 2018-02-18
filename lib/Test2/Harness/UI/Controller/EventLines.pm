package Test2::Harness::UI::Controller::EventLines;
use strict;
use warnings;

use Data::GUID;
use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Event Lines' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    use Data::Dumper;
    print Dumper($route);

    my $req = $self->{+REQUEST};
    my $res = resp(200);
    my $user = $req->user;
    my $schema = $self->{+CONFIG}->schema;


    die error(404 => 'Missing route') unless $route;
    my $it = $route->{name_or_id} or die error(404 => 'No name or id');

    if ($route->{from} eq 'job') {
        my $job_id = $it;
        my $job = $schema->resultset('Job')->find({job_id => $job_id})
            or die error(404 => 'Invalid Job');

        $job->verify_access('r', $user) or die error(401);

        my @lines = $schema->resultset('EventLine')->search(
            {'event.job_id' => $job_id},
            {
                join => 'event',
                order_by => ['event.event_ord', 'facet', 'tag'],
            },
        )->all;

        $res->stream(
            env          => $req->env,
            content_type => 'application/x-jsonl',

            done  => sub { !@lines },
            fetch => sub {
                return unless @lines && $lines[0];

                my $event_id = $lines[0]->event_id;
                my $event = {event_id => $event_id, lines => []};

                while (@lines) {
                    last if $lines[0]->event_id ne $event_id;
                    push @{$event->{lines}} => shift @lines;
                }

                return encode_json($event) . "\n";
            },
        );

        return $res;
    }

#    my $query = [{name => $it}];
#    push @$query => {run_id => $it} if eval { Data::GUID->from_string($it) };
#
#    my $run = $user->runs($query)->first or die error(404 => 'Invalid run');
#
#    my $offset = 0;
#    $res->stream(
#        env          => $req->env,
#        content_type => 'application/x-jsonl',
#
#        done  => sub { $run->complete },
#        fetch => sub {
#            my @jobs = map {encode_json($_) . "\n"} sort _sort_jobs $run->jobs(undef, {offset => $offset, order_by => {-asc => 'stream_ord'}})->all;
#            $offset += @jobs;
#            return @jobs;
#        },
#    );

    die error(501);
}

1;
