package Test2::Harness::UI::Import;
use strict;
use warnings;

use DateTime;

use Carp qw/croak/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::UI::Util::HashBase qw/-schema/;

sub init {
    my $self = shift;

    croak "'schema' is a required attribute"
        unless $self->{+SCHEMA};
}

sub _fail {
    my $self = shift;
    my ($msg, %params) = @_;

    my $out = {%params};
    push @{$out->{errors}} => $msg;

    return $out;
}

sub import_events {
    my $self = shift;

    my $schema = $self->{+SCHEMA};
    $schema->txn_begin;

    my $out;
    my $ok = eval { $out = $self->process_params(@_); 1 };
    my $err = $@;

    if (!$ok) {
        warn $@;
        $schema->txn_rollback;
        return { errors => ['Internal Error'], internal_error => 1 };
    }

    if ($out->{errors} && @{$out->{errors}}) {
        $schema->txn_rollback;
    }
    else {
        $schema->txn_commit;
    }

    return $out;
}

sub process_params {
    my $self = shift;
    my ($params) = @_;

    $params = decode_json($params) unless ref $params;

    # Verify credentials
    my $user = $self->verify_credentials($params->{username}, $params->{password})
        or return $self->_fail("Incorrect credentials");

    # Verify or create feed
    my ($feed, $error) = $self->find_feed($user, $params);
    return $error if $error;

    my $cnt = 0;
    for my $event (@{$params->{events}}) {
        my $error = $self->import_event($feed, $event);
        return $self->_fail("error processing event number $cnt: $error") if $error;
        $cnt++;
    }

    return {success => 1, events_added => $cnt, feed => $feed->feed_ui_id};
}

sub find_feed {
    my $self = shift;
    my ($user, $params) = @_;

    my $schema = $self->{+SCHEMA};

    # New feed!
    my $feed_ui_id = $params->{feed}
        or return $schema->resultset('Feed')->create({user_ui_id => $user->user_ui_id, permissions => $params->{permissions} || 'private'});

    # Verify existing feed

    my $feed = $schema->resultset('Feed')->find({user_ui_id => $user->user_ui_id, feed_ui_id => $feed_ui_id})
        or return $self->_fail("Invalid feed");

    return $self->_fail("permissions ($params->{permissions}) do not match established permissions (" . $feed->permissions . ") for this feed ($feed_ui_id)")
        unless $feed->permissions eq $params->{permissions};

    return $feed;
}

sub verify_credentials {
    my $self = shift;
    my ($username, $password) = @_;

    return undef unless defined $username;
    return undef unless defined $password;

    my $schema = $self->{+SCHEMA};
    my $user = $schema->resultset('User')->find({username => $username})
        or return undef;

    return $user if $user->verify_password($password);
}

sub format_stamp {
    my $stamp = shift;
    return undef unless $stamp;

    my $out = DateTime->from_epoch(epoch => $stamp)->stringify;
    $out .= $1 if sprintf("%.10f", $stamp) =~ m/(\.\d+)$/;

    return $out;
}

sub import_event {
    my $self = shift;
    my ($feed, $event_data) = @_;

    my $schema = $self->{+SCHEMA};

    my $run_id = $event_data->{run_id};
    return "no run_id provided" unless defined $run_id;
    my $run = $schema->resultset('Run')->find_or_create({feed_ui_id => $feed->feed_ui_id, run_id => $run_id, permissions => $feed->permissions})
        or die "Unable to find/add run: $run_id";

    my $job_id = $event_data->{job_id};
    return "no job_id provided" unless defined $job_id;
    my $job = $schema->resultset('Job')->find_or_create({job_id => $job_id, run_ui_id => $run->run_ui_id, permissions => $feed->permissions});

    my $event = $schema->resultset('Event')->create(
        {
            job_ui_id => $job->job_ui_id,
            stamp     => format_stamp($event_data->{stamp}),
            event_id  => $event_data->{event_id},
            stream_id => $event_data->{stream_id},
        }
    );
    die "Could not create event" unless $event;

    my $facets = $event_data->{facet_data} || {};
    for my $facet_name (keys %$facets) {
        my $vals = $facets->{$facet_name} or next;
        $vals = [$vals] unless ref($vals) eq 'ARRAY';

        my $cnt = 0;
        for my $val (@$vals) {
            my $facet = $schema->resultset('Facet')->create({
                event_ui_id => $event->event_ui_id,
                facet_name => $facet_name,
                facet_value => encode_json($val),
            });
            die "Could not add facet '$facet_name' number $cnt" unless $facet;
            $cnt++;

            $run->update({facet_ui_id => $facet->facet_ui_id}) if $facet_name eq 'harness_run' && !$run->facet_ui_id;
            $job->update({facet_ui_id => $facet->facet_ui_id, file => $val->{file}}) if $facet_name eq 'harness_job' && !$job->facet_ui_id;
        }
    }

    return;
}

1;
