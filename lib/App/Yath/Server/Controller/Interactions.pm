package App::Yath::Server::Controller::Interactions;
use strict;
use warnings;

our $VERSION = '2.000005';

use DateTime;
use Scalar::Util qw/blessed/;
use App::Yath::Server::Response qw/resp error/;
use App::Yath::Util qw/share_dir/;
use App::Yath::Schema::Util qw/find_job is_mysql/;
use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'Yath';

    my $req = $self->{+REQUEST};

    my $schema = $self->schema;
    my $id     = $route->{id} or die error(404 => 'No event id provided');

    my $event = $schema->resultset('Event')->find_by_id_or_uuid($id)
        or die error(404 => 'Invalid Event');

    my $context = $route->{context} // 1;
    return $self->data($id, $context) if $route->{data};

    my $res = resp(200);
    $res->add_css('view.css');
    $res->add_css('interactions.css');
    $res->add_js('runtable.js');
    $res->add_js('jobtable.js');
    $res->add_js('eventtable.js');
    $res->add_js('interactions.js');

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $base_uri = $req->base->as_string;
    my $data_uri = join '/' => $base_uri . 'interactions', 'data', $id, $context;

    my $content = $tx->render(
        'interactions.tx',
        {
            base_uri      => $req->base->as_string,
            event_id      => $event->event_uuid,
            user          => $req->user,
            data_uri      => $data_uri,
            context_count => $context,
        }
    );

    $res->raw_body($content);
    return $res;
}

sub data {
    my $self = shift;
    my ($id, $context) = @_;

    my $schema = $self->schema;

    # Get event
    my $event = $schema->resultset('Event')->find_by_id_or_uuid($id)
        or die error(404 => 'Invalid Event');

    my $stamp = $event->get_column('stamp') or die error(500 => "Requested event does not have a timestamp");

    # Get job id
    my $try = $event->job_try;
    my $job = $try->job;
    my $run = $job->run;

    # Get tests from run where the start and end surround the event
    my $try_rs = $schema->resultset('JobTry')->search(
        {
            'job.job_id' => {'!=' => $job->job_id},
            'me.ended' => {'>=' => $stamp },
            '-or' => [
                {'me.launch' => {'<=' => $stamp}},
                {'me.start' => {'<=' => $stamp}},
            ],
        },
        {
            join     => 'job',
            order_by => 'job_try_id',
        },
    );

    my $req = $self->{+REQUEST};
    my $res = resp(200);

    my ($event_rs, %seen_events);
    my @out = (
        {type => 'run',   data => $run},
        {type => 'job',   data => $job->glance_data(try_id => $try->job_try_id)},
        {type => 'event', data => $event->line_data},
        {type => 'count', data => $try_rs->count},
    );

    my $advance = sub {
        return 0 if @out;

        while ($event_rs) {
            if (my $e = $event_rs->next) {
                if ($e->is_subtest) {
                    next unless $self->subtest_in_context($e, $event->stamp, $context);
                }

                # If event is in a subtest show the whole subtest, top level subtest
                $e = $e->parent while $e->nested;

                next if $seen_events{$e->event_id}++;

                push @out => {type => 'event', data => $e->line_data};
                return 0;
            }

            $event_rs = undef;
        }

        if (my $try = $try_rs->next) {
            my $job = $try->job;
            push @out => {type => 'job', data => $job->glance_data(try_id => $try->job_try_id)};

            $event_rs = $try->events(
                {
                    '-or' => [
                        {is_subtest => 1, nested => 0},
                        {
                            '-and' => [
                                {stamp => {'<=' => $self->interval($stamp, '+', $context)}},
                                {stamp => {'>=' => $self->interval($stamp, '-', $context)}},
                            ],
                        },
                    ],
                },
                {order_by => ['event_idx', 'event_sdx']},
            );

            return 0;
        }

        return 1;
    };

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        done => $advance,

        fetch => sub {
            $advance->() unless @out;
            return @out ? encode_json(shift(@out)) . "\n" : ();
        },
    );

    return $res;
}

sub subtest_in_context {
    my $self = shift;
    my ($event, $stamp, $context) = @_;

    my $f = $event->facets or return 1;

    my $parent = $f->{parent}           or return 1;
    my $start  = $parent->{start_stamp} or return 1;
    my $stop   = $parent->{stop_stamp}  or return 1;

    $start = DateTime->from_epoch(epoch => $start, time_zone => 'local');
    $stop  = DateTime->from_epoch(epoch => $stop,  time_zone => 'local');

    # Need an extra nanosecond because is_between does not check for >= or <= just > or <.
    $start->subtract(seconds => $context, nanoseconds => 1);
    $stop->add(seconds => $context, nanoseconds => 1);

    return $stamp->is_between($start, $stop) ? 1 : 0;
}

sub interval {
    my $self = shift;
    my ($stamp, $op, $context) = @_;

    return \"timestamp '$stamp' $op INTERVAL '$context' second"
        unless is_mysql();

    # *Sigh* MySQL
    return \"DATE_ADD('$stamp', INTERVAL $context second)" if $op eq '+';
    return \"DATE_SUB('$stamp', INTERVAL $context second)";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::Interactions - Check for interactions between tests

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

