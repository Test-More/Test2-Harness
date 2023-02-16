package Test2::Harness::UI::Controller::Interactions;
use strict;
use warnings;

our $VERSION = '0.000133';

use DateTime;
use Data::GUID;
use Scalar::Util qw/blessed/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::UI::Util qw/share_dir find_job/;
use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'YathUI';

    my $req = $self->{+REQUEST};

    my $id      = $route->{id}      or die error(404 => 'No event id provided');
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
            base_uri   => $req->base->as_string,
            event_id   => $id,
            user       => $req->user,
            data_uri   => $data_uri,
            context_count => $context,
        }
    );

    $res->raw_body($content);
    return $res;
}

sub data {
    my $self = shift;
    my ($id, $context) = @_;

    my $schema = $self->{+CONFIG}->schema;
    # Get event
    my $event = $schema->resultset('Event')->search({event_id => $id})->first
        or die error(404 => 'Invalid Event');

    my $stamp = $event->get_column('stamp') or die "No stamp?!";

    # Get job
    my $job = $event->job_key or die error(500 => "Could not find job");

    # Get run from event
    my $run = $job->run or die error(500 => "Could not find run");

    # Get tests from run where the start and end surround the event
    my $job_rs = $run->jobs(
        {
            job_key => {'!=' => $job->job_key},
            ended => {'>=' => $stamp},
            '-or' => [
                {launch => {'<=' => $stamp}},
                {start => {'<=' => $stamp}},
            ],
        },
        {order_by => 'job_ord'},
    );

    my $req = $self->{+REQUEST};
    my $res = resp(200);

    my ($event_rs, %seen_events);
    my @out = (
        {type => 'run',   data => $run},
        {type => 'job',   data => $job->glance_data},
        {type => 'event', data => $event->line_data},
        {type => 'count', data => $job_rs->count},
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

        if (my $job = $job_rs->next) {
            push @out => {type => 'job', data => $job->glance_data};

            $event_rs = $job->events(
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
                {order_by => 'event_ord'},
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

    my $driver = $self->{+CONFIG}->db_driver;

    return \"timestamp '$stamp' $op INTERVAL '$context' seconds" if $driver eq 'PostgreSQL';

    # *Sigh* MySQL
    return \"DATE_ADD('$stamp', INTERVAL $context second)" if $op eq '+';
    return \"DATE_SUB('$stamp', INTERVAL $context second)";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Interactions

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

