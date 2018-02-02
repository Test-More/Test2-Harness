package Test2::Harness::UI::Import;
use strict;
use warnings;

use DateTime;

use Carp qw/croak/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::UI::Util::HashBase qw/-schema -feed_name -file -user -permissions -_feed -filename/;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip qw($GunzipError) ;

sub init {
    my $self = shift;

    croak "'schema' is a required attribute"
        unless $self->{+SCHEMA};

    croak "'feed_name' is a required attribute"
        unless $self->{+FEED_NAME};

    croak "'file' is a required attribute"
        unless $self->{+FILE};

    croak "'user' is a required attribute"
        unless $self->{+USER};

    croak "'permissions' is a required attribute"
        unless $self->{+PERMISSIONS};

    croak "'filename' is a required attribute"
        unless $self->{+FILENAME};
}

sub run {
    my $self = shift;

    my $schema = $self->{+SCHEMA};
    $schema->txn_begin;

    my $out;
    my $ok = eval { $out = $self->process; 1 };
    my $err = $@;

    if (!$ok) {
        warn $@;
        $schema->txn_rollback;
        die $err;
    }

    if   ($out->{success}) { $schema->txn_commit }
    else                   { $schema->txn_rollback }

    return $out;
}

sub process {
    my $self = shift;

    my $cnt = 0;

    my $filename = $self->{+FILENAME};
    my $file = $self->{+FILE};
    my $fh;

    if ($filename =~ m/\.jsonl\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new($file) or die "Could not open bz2 file '$file': $Bunzip2Error";
    }
    elsif ($filename =~ m/\.jsonl\.gz$/) {
        $fh = IO::Uncompress::Gunzip2->new($file) or die "Could not open gz file '$file': $GunzipError";
    }
    elsif ($filename =~ m/\.jsonl$/) {
        open($fh, '<', $file) or die "Could not open uploaded file '$file': $!";
    }
    else {
        return {errors => ["Unsupported file type, must be .jsonl, .jsonl.bz2, or .jsonl.gz"]};
    }

    while (my $line = <$fh>) {
        my $event = eval { decode_json($line) };
        my $error = $event ? $self->import_event($event) : $@;
        return {errors => ["error processing event number $cnt: $error"]} if $error;
        $cnt++;
    }

    return {success => $cnt};
}

sub feed {
    my $self = shift;

    return $self->{+_FEED} ||= $self->{+SCHEMA}->resultset('Feed')->create(
        {
            user_ui_id  => $self->user->user_ui_id,
            name        => $self->{+FEED_NAME},
            permissions => $self->{+PERMISSIONS},
        }
    );
}

sub format_stamp {
    my $stamp = shift;
    return undef unless $stamp;
    return DateTime->from_epoch(epoch => $stamp);
}

sub vivify_row {
    my $self = shift;
    my ($type, $field, $find, $create) = @_;

    return (undef, "No $field provided") unless defined $find->{$field};

    my $schema = $self->{+SCHEMA};
    my $row = $schema->resultset($type)->find($find);
    return $row if $row;

    return $schema->resultset($type)->create({%$find, %$create}) || die "Unable to find/add $type: $find->{$field}";
}

sub unique_row {
    my $self = shift;
    my ($type, $field, $find, $create) = @_;

    return (undef, "No $field provided") unless defined $find->{$field};

    my $schema = $self->{+SCHEMA};
    return (undef, "Duplicate $type") if $schema->resultset($type)->find($find);
    return $schema->resultset($type)->create({%$find, %$create}) || die "Could not create $type";
}

sub import_event {
    my $self = shift;
    my ($event_data) = @_;

    my $feed = $self->feed;

    my ($run, $run_error) = $self->vivify_row(
        'Run' => 'run_id',
        {feed_ui_id  => $feed->feed_ui_id, run_id => $event_data->{run_id}},
        {permissions => $feed->permissions},
    );
    return $run_error if $run_error;

    my ($job, $job_error) = $self->vivify_row(
        'Job' => 'job_id',
        {run_ui_id   => $run->run_ui_id, job_id => $event_data->{job_id}},
        {permissions => $feed->permissions},
    );
    return $job_error if $job_error;

    return "No event_id provided" unless $event_data->{event_id};

    my ($event, $error) = $self->unique_row(
        'Event' => 'event_id',
        {
            job_ui_id => $job->job_ui_id,
            event_id  => $event_data->{event_id},
            processed => format_stamp($event_data->{processed}),
        },
        {
            stamp     => format_stamp($event_data->{stamp}),
            stream_id => $event_data->{stream_id},
        },
    );
    return $error if $error;

    return $self->import_facets($event, $event_data->{facet_data});
}

sub import_facets {
    my $self = shift;
    my ($event, $facets) = @_;

    return unless $facets;

    for my $facet_name (keys %$facets) {
        my $val = $facets->{$facet_name} or next;

        unless (ref($val) eq 'ARRAY') {
            $self->import_facet($event, $facet_name, $val);
            next;
        }

        $self->import_facet($event, $facet_name, $_) for @$val;
    }

    return;
}

sub import_facet {
    my $self = shift;
    my ($event, $facet_name, $val) = @_;

    my $schema = $self->{+SCHEMA};

    my $facet = $schema->resultset('Facet')->create(
        {
            event_ui_id => $event->event_ui_id,
            facet_name  => $facet_name,
            facet_value => encode_json($val),
        }
    );
    die "Could not add facet '$facet_name'" unless $facet;

    if ($facet_name eq 'harness_run') {
        my $run = $event->run;
        $run->update({facet_ui_id => $facet->facet_ui_id}) unless $run->facet_ui_id;
    }
    elsif ($facet_name eq 'harness_job') {
        my $job = $event->job;
        $job->update({job_facet_ui_id => $facet->facet_ui_id}) unless $job->job_facet_ui_id;
    }
    elsif ($facet_name eq 'harness_job_end') {
        my $job = $event->job;
        $job->update({end_facet_ui_id => $facet->facet_ui_id, file => $val->{file}, fail => $val->{fail}}) unless $job->end_facet_ui_id;
    }

    return $facet;
}

1;
