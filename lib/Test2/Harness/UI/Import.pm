package Test2::Harness::UI::Import;
use strict;
use warnings;

use DateTime;
use Data::GUID;
use Time::HiRes qw/time/;
use List::Util qw/first/;

use Carp qw/croak/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Formatter::Test2::Composer;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip  qw($GunzipError);

use Test2::Harness::UI::Util::HashBase qw{
    -config -run -mode
    -passed -failed
    -job0_id -job_ord -job_buffer -ready_jobs
};

my %MODES = (
    summary  => 5,
    qvf      => 10,
    qvfd     => 15,
    complete => 20,
);

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

    my $mode = $self->{+RUN}->mode;
    $self->{+MODE} = $MODES{$mode} or croak "Invalid mode '$mode'";

    $self->{+PASSED} = 0;
    $self->{+FAILED} = 0;

    $self->{+JOB_ORD}    = 1;
    $self->{+JOB0_ID}    = gen_uuid();
    $self->{+JOB_BUFFER} = {
        $self->{+JOB0_ID} => {
            job_id  => $self->{+JOB0_ID},
            job_ord => $self->{+JOB_ORD}++,
            run_id  => $self->{+RUN}->run_id,
            name    => "HARNESS INTERNAL LOG",
        },
    };
}

sub process {
    my $self = shift;

    my $run = $self->{+RUN};
    my $log = $run->log_file or die "No log file";

    my $fh;
    if ($log->name =~ m/\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new(\($log->data)) or die "Could not open bz2 data: $Bunzip2Error";
    }
    else {
        $fh = IO::Uncompress::Gunzip->new(\($log->data)) or die "Could not open gz data: $GunzipError";
    }

    my $schema = $self->{+CONFIG}->schema;

    local $| = 1;
    my $last = 0;
    while (my $line = <$fh>) {
        my $ln = $.;
        if (time - $last >= 0.1) {
            print "$ln\r";
            $last = time;
        }

        my $error = $self->process_event_json($ln => $line);
        $error ||= $self->flush_ready_jobs() if $self->{+READY_JOBS} && @{$self->{+READY_JOBS}};

        return {errors => ["error processing line number $ln: $error"]} if $error;
    }

    $self->flush_all_jobs();

    return {success => 1, passed => $self->{+PASSED}, failed => $self->{+FAILED}};
}

sub flush_ready_jobs {
    my $self = shift;

    my $jobs = delete $self->{+READY_JOBS};
    return unless $jobs && @$jobs;

    my @events;

    my $mode = $self->{+MODE};

    for my $job (@$jobs) {
        delete $job->{event_ord};
        my $events = delete $job->{events};

        next if $mode <= $MODES{summary};

        my $record_job = $mode >= $MODES{complete} ? 1 : 0;
        $record_job ||= 1 if $job->{job_id} eq $self->{+JOB0_ID};
        $record_job ||= 1 if $mode >= $MODES{qvf} && $job->{fail};;

        my @local_events;
        for my $event (sort { $a->{event_ord} <=> $b->{event_ord} } values %$events) {
            my $is_diag = delete $event->{is_diag};
            my $record_event = $record_job || ($mode >= $MODES{qvfd} && $is_diag);
            next unless $record_event;

            clean($event->{facets});
            clean($event->{orphan});

            $event->{facets} = encode_json($event->{facets}) if $event->{facets};
            $event->{orphan} = encode_json($event->{orphan}) if $event->{orphan};
            push @events => $event;
        }
    }

    my $schema = $self->{+CONFIG}->schema;
    $schema->txn_begin;
    my $ok = eval {
        my $start = time;
        local $ENV{DBIC_DT_SEARCH_OK} = 1;
        $schema->resultset('Job')->populate($jobs);
        $schema->resultset('Event')->populate(\@events);
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

sub flush_all_jobs {
    my $self = shift;

    my $all = delete $self->{+JOB_BUFFER};
    push @{$self->{+READY_JOBS}} => values %$all;

    $self->flush_ready_jobs();
}

sub process_event_json {
    my $self = shift;
    my ($ln, $json) = @_;

    my $data;
    eval { $data = decode_json($json); 1 } or return "Error decoding facets for line $ln: $@";
    return "No event for line $ln" unless $data;

    my $f = $data->{facet_data} or return "No facet data for event on line $ln.";

    return $self->process_event($f, %$data, line => $ln);
}

sub process_event {
    my $self = shift;
    my ($f, %params) = @_;

    my $job_id = $f->{harness}->{job_id};
    $job_id = $self->{+JOB0_ID} if !$job_id || $job_id eq '0';
    my $job = $self->{+JOB_BUFFER}->{$job_id} ||= {
        job_id      => $job_id,
        job_ord     => $self->{+JOB_ORD}++,
        run_id      => $self->{+RUN}->run_id,
        events      => {},
        event_ord   => 1,
        fail_count  => 0,
        pass_count  => 0,
    };

    my $e_id = $f->{harness}->{event_id};
    my $e = $job->{events}->{$e_id} ||= {
        event_id => $f->{harness}->{event_id},
        job_id   => $job->{job_id},
    };

    my $nested = $f->{hubs}->[0]->{nested} || 0;

    $e->{trace_id} ||= $f->{trace}->{uuid};
    $e->{stamp}    ||= format_stamp($params{stamp});
    $e->{nested}   //= $nested;

    $e->{is_diag} //=
           ($f->{errors} && @{$f->{errors}})
        || ($f->{assert} && !($f->{assert}->{pass} || $f->{amnesty}))
        || ($f->{info} && grep { $_->{debug} || $_->{important} } @{$f->{info}});

    my $orphan = $nested ? 1 : 0;
    if (my $p = $params{parent_id}) {
        $e->{parent_id} ||= $p;
        $orphan = 0;
    }

    if ($orphan) {
        $e->{orphan} = $f;
        $e->{orphan_line} = $params{line};

        return;
    }

    $e->{event_ord} ||= $job->{event_ord}++;
    $e->{facets} = $f;
    $e->{facets_line} = $params{line};

    if ($f->{parent} && $f->{parent}->{children}) {
        $self->process_event($_, parent_id => $e_id, line => $params{line}) for @{$f->{parent}->{children}};
        $f->{parent}->{children} = "Removed, used to populate events table";
    }

    return if $nested;

    if ($f->{assert}) {
        if (causes_fail($f)) {
            $job->{fail_count}++;
        }
        else {
            $job->{pass_count}++;
        }
    }
    elsif (causes_fail($f)) {
        $job->{fail_count}++;
    }

    $self->update_other($job, $f) if first { $f->{$_} } qw{
        harness_job harness_job_exit harness_job_start harness_job_launch harness_job_end
        memory times
        harness_run
    };

    return;
}

sub update_other {
    my $self = shift;
    my ($job, $f) = @_;

    if (my $run_data = $f->{harness_run}) {
        clean($run_data);
        $self->{+RUN}->update({parameters => $run_data});
    }

    # Handle job events
    if (my $job_data = $f->{harness_job}) {
        $job->{file} ||= $job_data->{file};
        $job->{name} ||= $job_data->{job_name};
        clean($job_data);
        $job->{parameters} = encode_json($job_data);
        $f->{harness_job}  = "Removed, see job with job_id $job->{job_id}";
    }
    if (my $job_exit = $f->{harness_job_exit}) {
        $job->{file} ||= $job_exit->{file};
        $job->{exit} = $job_exit->{exit};

        $job->{stderr} = clean_output(delete $job_exit->{stderr});
        $job->{stdout} = clean_output(delete $job_exit->{stdout});
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
        $job->{fail}  = $job_end->{fail};
        $job->{ended} = format_stamp($job_end->{stamp});

        $job->{fail} ? $self->{+FAILED}++ : $self->{+PASSED}++;

        # All done
        push @{$self->{+READY_JOBS}} => delete $self->{+JOB_BUFFER}->{$job->{job_id}};
    }
    if (my $memory = $f->{memory}) {
        $job->{mem_peak}   = $memory->{peak}->[0];
        $job->{mem_peak_u} = $memory->{peak}->[1];
        $job->{mem_size}   = $memory->{size}->[0];
        $job->{mem_size_u} = $memory->{size}->[1];
        $job->{mem_rss}    = $memory->{rss}->[0];
        $job->{mem_rss_u}  = $memory->{rss}->[1];
    }
    if (my $times = $f->{times}) {
        $job->{time_user}  = $times->{user};
        $job->{time_sys}   = $times->{sys};
        $job->{time_cuser} = $times->{cuser};
        $job->{time_csys}  = $times->{csys};
    }
}

sub clean_output {
    my $text = shift;

    return undef unless defined $text;
    $text =~ s/^T2-HARNESS-ESYNC: \d+\n//gm;
    chomp($text);

    return undef unless length($text);
    return $text;
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

