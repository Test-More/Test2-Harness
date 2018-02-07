package Test2::Harness::UI::Import;
use strict;
use warnings;

use DateTime;
use Data::GUID;
use Time::HiRes qw/time/;

use Carp qw/croak/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::UI::Util::HashBase qw/-config -run -buffer -ready -job_ord/;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip qw($GunzipError);

sub format_stamp {
    my $stamp = shift;
    return undef unless $stamp;
    return DateTime->from_epoch(epoch => $stamp);
}

sub init {
    my $self = shift;

    croak "'config' is a required attribute"
        unless $self->{+CONFIG};

    croak "'run' is a required attribute"
        unless $self->{+RUN};

    $self->{+BUFFER} = {};
    $self->{+READY}  = [];
    $self->{+JOB_ORD} = 0;
}

sub process {
    my $self = shift;

    my $run  = $self->{+RUN};
    my $file = $run->log_file;

    my $fh;
    if ($file =~ m/\.jsonl\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new($file) or die "Could not open bz2 file '$file': $Bunzip2Error";
    }
    elsif ($file =~ m/\.jsonl\.gz$/) {
        $fh = IO::Uncompress::Gunzip2->new($file) or die "Could not open gz file '$file': $GunzipError";
    }
    elsif ($file =~ m/\.jsonl$/) {
        open($fh, '<', $file) or die "Could not open uploaded file '$file': $!";
    }
    else {
        return {errors => ["Unsupported file type, must be .jsonl, .jsonl.bz2, or .jsonl.gz"]};
    }

    my $schema = $self->{+CONFIG}->schema;

    my $last = 0;
    while (my $line = <$fh>) {
        my $ord = $.;
        if (time - $last >= 0.1) {
            local $| = 1;
            print "$ord\r";
            $last = time;
        }
        my $event_data;
        my $ok = eval { $event_data = decode_json($line) };
        my $error = $@;

        if ($ok && $event_data) {
            clean($event_data);
            $error = $self->process_event($ord, $event_data->{facet_data});
        }

        $self->flush_ready if @{$self->{+READY}};

        return {errors => ["error processing line number $.: $error"]} if $error || !$ok;
    }

    $self->flush_all;

    return {success => 1};
}

sub flush_ready {
    my $self = shift;

    my $ready = delete $self->{+READY};
    $self->{+READY} = [];

    my $schema = $self->{+CONFIG}->schema;

    $schema->txn_begin;
    my $ok = eval {
        local $ENV{DBIC_DT_SEARCH_OK} = 1;
        $schema->resultset('Job')->populate($ready);
        1;
    };
    my $err = $@;

    if ($ok) {
        $schema->txn_commit;
        return;
    }

    $schema->txn_rollback;
    die $err;
}

sub flush_all {
    my $self = shift;

    my $buffer = delete $self->{+BUFFER};

    push @{$self->{+READY}} => values %$buffer;

    $self->flush_ready;
    return;
}

sub process_event {
    my $self = shift;
    my ($ord, $f) = @_;

    my $run    = $self->{+RUN};
    my $buffer = $self->{+BUFFER} ||= {};

    my $job_id = $f->{harness}->{job_id};
    return (undef, "No 'job_id'") unless defined $job_id;

    my $jord = $self->{+JOB_ORD}++;
    my $job = $buffer->{$job_id} ||= {
        job_id  => Data::GUID->new->as_string,
        job_ord => $jord,
        run_id  => $run->run_id,
        events  => [],
    };

    my $job_db_id = $job->{job_id};

    # Handle the run event
    if (my $run_data = $f->{harness_run}) {
        $run->update({parameters => encode_json($run_data)});
        $f->{harness_run} = "Removed, see run with run_id " . $run->run_id;
    }

    # Handle job events
    if (my $job_data = $f->{harness_job}) {
        $job->{file} ||= $job_data->{file};
        $job->{parameters} = encode_json($job_data);
        $f->{harness_job} = "Removed, see job with job_id $job_db_id";
    }
    if (my $job_exit = $f->{harness_job_exit}) {
        $job->{file} ||= $job_exit->{file};
        $job->{exit} = $job_exit->{exit};
    }
    if (my $job_start = $f->{harness_job_start}) {
        $job->{file} ||= $job_start->{file};
        $job->{start} = format_stamp($job_start->{stamp});
    }
    if (my $job_launch = $f->{harness_job_launch}) {
        $job->{file} ||= $job_launch->{file};
        $job->{launch} = format_stamp($job_launch->{stamp});
    }
    if (my $job_end = $f->{harness_job_end}) {
        $job->{file} ||= $job_end->{file};
        $job->{fail} = $job_end->{fail};
        $job->{ended} = format_stamp($job_end->{stamp});

        # All done!
        push @{$self->{+READY}} => delete $buffer->{$job_id};
    }

    my ($event, $error) = $self->process_facets($ord, $f, $job_db_id);
    return $error if $error || !$event;
    push @{$job->{events}} => $event;

    return;
}

sub process_facets {
    my $self = shift;
    my ($ord, $f, $job_db_id, $parent_db_id) = @_;

    my $db_id = Data::GUID->new->as_string;

    my $row = {
        event_id  => $db_id,
        event_ord => $ord,
        job_id    => $job_db_id,
        parent_id => $parent_db_id,

        nested => $f->{trace} ? ($f->{trace}->{nested} || 0) : 0,
        causes_fail => causes_fail($f) ? 1 : 0,

        is_parent => $f->{parent} ? 1 : 0,
        is_assert => $f->{assert} ? 1 : 0,
        is_plan   => $f->{plan}   ? 1 : 0,

        assert_pass => $f->{assert} ? $f->{assert}->{pass} : undef,
        plan_count  => $f->{plan}   ? $f->{plan}->{count}  : undef,
    };

    if ($f->{parent} && $f->{parent}->{children}) {
        my $cnt = 0;
        for my $child (@{$f->{parent}->{children}}) {
            my ($crow, $error) = $self->process_facets($cnt, $child, $job_db_id, $db_id);
            return (undef, "Error in subevent [$cnt]: $error") if $error || !$crow;
            push @{$row->{events}} => $crow;
            $cnt++;
        }

        $f->{parent}->{children} = "Removed, see events with parent_id $db_id";
    }

    $row->{facets} = encode_json($f);

    return ($row, undef);
}

sub clean {
    my ($s) = @_;
    return 0 unless defined $s;
    my $r = ref($_[0]) or return 1;
    if    ($r eq 'HASH')  { return clean_hash(@_) }
    elsif ($r eq 'ARRAY') { return clean_array(@_) }
    return 1;
}

sub clean_hash {
    my ($s) = @_;
    my $vals = 0;

    for my $key (keys %$s) {
        my $v = clean($s->{$key});
        if   ($v) { $vals++ }
        else      { delete $s->{$key} }
    }

    $_[0] = undef unless $vals;

    return $vals;
}

sub clean_array {
    my ($s) = @_;

    @$s = grep { clean($_) } @$s;

    return @$s if @$s;

    $_[0] = undef;
    return 0;
}


1;

__END__

    display_level   edisp_lvl   NOT NULL,

    nested          INT         NOT NULL,
    causes_fail     BOOL        NOT NULL,

    is_parent       BOOL        NOT NULL,
    is_assert       BOOL        NOT NULL,
    is_plan         BOOL        NOT NULL,

    assert_pass     BOOL        DEFAULT NULL,
    plan_count      INTEGER     DEFAULT NULL,

    facets          JSONB       NOT NULL,

        no_display => $f->{about}           ? ($f->{about}->{no_display}          ? 1 : 0) : 0,
        no_render  => $f->{harness_watcher} ? ($f->{harness_watcher}->{no_render} ? 1 : 0) : 0,
