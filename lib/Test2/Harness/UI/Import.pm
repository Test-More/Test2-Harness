package Test2::Harness::UI::Import;
use strict;
use warnings;

use DateTime;

use Carp qw/croak/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::UI::Util::HashBase qw/-schema -feed -cache/;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip qw($GunzipError) ;

sub init {
    my $self = shift;

    croak "'schema' is a required attribute"
        unless $self->{+SCHEMA};

    croak "'feed' is a required attribute"
        unless $self->{+FEED};

    $self->{+CACHE} = {};
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

    my $feed  = $self->{+FEED};
    my $orig  = $feed->orig_file;
    my $local = $feed->local_file;

    my $fh;
    if ($orig =~ m/\.jsonl\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new($local) or die "Could not open bz2 file '$local': $Bunzip2Error";
    }
    elsif ($orig =~ m/\.jsonl\.gz$/) {
        $fh = IO::Uncompress::Gunzip2->new($local) or die "Could not open gz file '$local': $GunzipError";
    }
    elsif ($orig =~ m/\.jsonl$/) {
        open($fh, '<', $local) or die "Could not open uploaded file '$local': $!";
    }
    else {
        return {errors => ["Unsupported file type, must be .jsonl, .jsonl.bz2, or .jsonl.gz"]};
    }

    my $schema = $self->{+SCHEMA};

    my @events;
    while (my $line = <$fh>) {
        next unless $line =~ m/"processed"\s?:/;
        my $event_data;
        my $ok = eval { $event_data = decode_json($line) };
        my $error = $@;

        my $event;
        if ($ok && $event_data) {
            next unless defined $event_data->{processed};
            $error = undef;
            ($event, $error) = $self->parse_event($event_data);
        }

        return {errors => ["error processing line number $.: $error"]} if $error;

        push @events => $event;

        if (@events >= 1000) {
            local $| = 1;
            syswrite(\*STDOUT, "$.\n");
            $schema->resultset('Event')->populate(\@events);
            @events = ();
        }
    }

    $schema->resultset('Event')->populate(\@events) if @events;

    return {success => 1};
}

sub format_stamp {
    my $stamp = shift;
    return undef unless $stamp;
    return DateTime->from_epoch(epoch => $stamp);
}

sub parse_event {
    my $self = shift;
    my ($event_data) = @_;

    my $feed   = $self->{+FEED};
    my $cache  = $self->{+CACHE};
    my $schema = $self->{+SCHEMA};

    return (undef, "No event_id provided") unless $event_data->{event_id};

    my $run = $cache->{run}->{$event_data->{run_id}} ||= $schema->resultset('Run')->find_or_create(
        {
            feed_ui_id => $feed->feed_ui_id,
            run_id     => $event_data->{run_id}
        },
    ) or return (undef, "Could not find or create run");

    my $job = $cache->{job}->{$event_data->{job_id}} ||= $schema->resultset('Job')->find_or_create(
        {
            run_ui_id => $run->run_ui_id,
            job_id => $event_data->{job_id}
        },
    ) or return (undef, "Could not find or create job");

    my $fields = {
        job_ui_id => $job->job_ui_id,
        event_id  => $event_data->{event_id},
        stream_id => $event_data->{stream_id},
        processed => format_stamp($event_data->{processed}),
        stamp     => format_stamp($event_data->{stamp}),
    };

    my $facet_data = {%{$event_data->{facet_data}}};
    for my $facet (Test2::Harness::UI::Schema::Result::Event->KNOWN_FACETS) {
        my $val = delete $facet_data->{$facet};

        my $type = ref($val) || '';

        my $empty = 1;
        $empty = 0 if $type eq 'ARRAY' && !@$val;
        $empty = 0 if $type eq 'HASH'  && !keys %$val;

        $fields->{$facet} = encode_json($val);

        if ($facet eq 'harness_job_end') {
            $job->update({file => $val->{file}, fail => $val->{fail}});
        }
        elsif($facet eq 'assert') {
            $fields->{assert_pass} = $val->{pass};
        }
        elsif($facet eq 'plan') {
            $fields->{plan_count} = $val->{count};
        }
        elsif($facet eq 'parent') {
            $fields->{is_hid} = $val->{hid};
        }
        elsif($facet eq 'trace') {
            $fields->{in_hid} = $val->{hid};
        }
    }

    $fields->{other_facets} = keys(%$facet_data) ? encode_json($facet_data) : undef;
    $fields->{causes_fail} = causes_fail($event_data->{facet_data});

    return ($fields);
}

1;
