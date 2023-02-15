package Test2::Harness::Renderer::UIDB;
use strict;
use warnings;

use Carp qw/croak/;
use Sys::Hostname qw/hostname/;

use DateTime;

use Time::HiRes qw/time/;
use Test2::Harness::UI::Config;
use Test2::Harness::UI::RunProcessor;
use Test2::Harness::Runner::State;
use Test2::Harness::UI::Util qw/config_from_settings/;
use Test2::Harness::Util::JSON qw/encode_json/;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util qw/mod2file/;

our $VERSION = '0.000130';

use parent 'Test2::Harness::Renderer';
use Test2::Harness::Util::HashBase qw{
    <run
    <processor
    <config
    <dbh
    <project
    <user
    <finished
    +links
    <error_count

    +resources +resource_interval +state +host

    <last_resource_stamp
};

sub init {
    my $self = shift;

    my $settings = $self->settings;

    my $yath = $settings->yathui;
    $self->{+PROJECT} //= $yath->project || die "The yathui-project option is required.\n";
    $self->{+USER} //= $yath->user || die "The yathui-user option is required.\n";

    $self->{+ERROR_COUNT} = 0;

    my $config = $self->{+CONFIG} //= config_from_settings($settings);

    my $dbh = $config->connect // die "Could not connect to the db";
    $dbh->{mysql_auto_reconnect} = 1 if $Test2::Harness::UI::Schema::LOADED =~ m/mysql/i;

    STDOUT->autoflush(1);
    print $self->links;
}

sub step {
    my $self = shift;

    $self->send_resources();
}

sub resource_interval {
    my $self = shift;
    return $self->{+RESOURCE_INTERVAL} //= $self->settings->yathui->resources;
}

sub state {
    my $self = shift;

    return $self->{+STATE} if $self->{+STATE};

    my $settings = $self->settings;

    return $self->{+STATE} = Test2::Harness::Runner::State->new(
        observe   => 1,
        job_count => $settings->runner->job_count // 1,
        workdir   => $settings->workspace->workdir,
    );
}

sub resources {
    my $self = shift;
    return $self->{+RESOURCES} if $self->{+RESOURCES};

    my $state = $self->state;
    $state->poll;

    return $self->{+RESOURCES} = [grep { $_ && $_->can('status_data') } @{$state->resources}];
}

sub send_resources {
    my $self = shift;

    return unless $self->{+RUN};

    my $interval = $self->resource_interval or return;
    my $resources = $self->resources or return;
    return unless @$resources;

    my $stamp = time;

    if (my $last = $self->{+LAST_RESOURCE_STAMP}) {
        my $delta = $stamp - $last;
        return unless $delta >= $interval;
    }

    unless(eval { $self->_send_resources($stamp => $resources); 1 }) {
        my $err = $@;
        warn "Non fatal error, could not send resource info to YathUI: $err";
        return;
    }

    return $self->{+LAST_RESOURCE_STAMP} = $stamp;
}

sub host {
    my $self = shift;
    return $self->{+HOST} //= $self->{+CONFIG}->schema->resultset('Host')->find_or_create({hostname => hostname(), host_id => gen_uuid()});
}

sub _send_resources {
    my $self = shift;
    my ($stamp, $resources) = @_;

    my $config = $self->{+CONFIG};

    my $run_id = $self->settings->run->run_id;
    my $host_id = $self->host->host_id;

    my $res_rs = $config->schema->resultset('Resource');

    $self->state->poll;

    my $dt_stamp = DateTime->from_epoch(epoch => $stamp, time_zone => 'local');

    for my $res (@$resources) {
        my $data = $res->status_data or next;

        my $item = {
            resource_id => gen_uuid,
            run_id      => $run_id,
            module      => ref($res) || $res,
            stamp       => $dt_stamp,
            data        => encode_json($data),
        };

        my $res = $res_rs->create($item);
    }

    return;
}

sub links {
    my $self = shift;
    return $self->{+LINKS} if defined $self->{+LINKS};

    if (my $url = $self->settings->yathui->url) {
        $self->{+LINKS} = "\nThis run can be reviewed at: $url/view/" . $self->settings->run->run_id . "\n\n";
    }

    return $self->{+LINKS} //= "";
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    $self->{+PROCESSOR}->set_signal($sig) if $self->{+PROCESSOR};

    my $run = $self->{+RUN} or return;
    $run->update({status => 'canceled', error => "Canceled with signal '$sig'"});
}

sub render_event {
    my $self = shift;
    my @args = @_;

    return if $self->{+ERROR_COUNT} >= 10;

    my $out;
    eval { $out = $self->_render_event(@args); 1 } and return $out;
    warn "YathUI-DB Renderer error:\n====\n$@\n====\n";

    $self->{+ERROR_COUNT}++;

    return unless $self->{+ERROR_COUNT} >= 10;
    warn "\n\n*************************\nThe YathUI-DB renderer has encountered 10+ errors, disabling...\n*************************\n\n";
}

sub _render_event {
    my $self = shift;
    my ($event) = @_;

    my $f = $event->{facet_data};

    if (my $runf = $f->{harness_run}) {
        my $run_id = $runf->{run_id} or die "No run-id?";

        my $config = $self->{+CONFIG};

        my $p = $config->schema->resultset('Project')->find_or_create({name => $self->{+PROJECT}, project_id => gen_uuid()});
        my $u = $config->schema->resultset('User')->find_or_create({username => $self->{+USER}, user_id => gen_uuid(), role => 'user'});

        my $ydb = $self->settings->prefix('yathui-db') or die "No DB settings";
        my $run = $config->schema->resultset('Run')->create({
            run_id     => $run_id,
            mode       => $self->settings->yathui->mode,
            buffer     => $ydb->buffering,
            status     => 'pending',
            user_id    => $u->user_id,
            project_id => $p->project_id,
        });

        $self->{+RUN} = $run;

        my $processor = Test2::Harness::UI::RunProcessor->new(
            config => $config,
            run => $run,
            interval => $ydb->flush_interval,
        );

        $self->{+PROCESSOR} = $processor;
        $processor->start();
    }
    elsif (!$self->{+RUN}) {
        die "Run was not seen!";
    }

    $self->{+PROCESSOR}->process_event($event, $f);
}

sub finish {
    my $self = shift;

    eval { $self->{+PROCESSOR}->finish(); 1 } or warn "YathUI-DB finish error:\n====\n$@\n====\n";

    $self->{+FINISHED} = 1;

    print $self->links;
}

sub DESTROY {
    my $self = shift;

    return if $self->{+FINISHED};

    my $run = $self->{+RUN} or return;
    $run->update({status => 'broken', error => 'Run did not finish'});
}

1;
