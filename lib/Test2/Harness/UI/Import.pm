package Test2::Harness::UI::Import;
use strict;
use warnings;

use DateTime;
use Data::GUID;
use Time::HiRes qw/time/;

use Carp qw/croak/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Formatter::Test2::Composer;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip  qw($GunzipError);

use Test2::Harness::UI::Util::HashBase qw{
    -config  -run
    -buffer  -ready
    -job_ord -event_ord
    -mode    -store_orphans
    -passed  -failed
    -cids    -hids
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

    $self->{+BUFFER} = {};
    $self->{+READY}  = [];
    $self->{+JOB_ORD} = 0;
    $self->{+EVENT_ORD} = 0;

    $self->{+CIDS} = {};
    $self->{+HIDS} = {};

    $self->{+PASSED} = 0;
    $self->{+FAILED} = 0;

    my $mode = $self->{+RUN}->mode;
    $self->{+MODE} = $MODES{$mode} or croak "Invalid mode '$mode'";

    $self->{+STORE_ORPHANS} = $self->{+RUN}->store_orphans;
}

sub eord {
    my $self = shift;
    return $self->{+EVENT_ORD}++;
}

sub process {
    my $self = shift;

    my $run  = $self->{+RUN};

    my $fh;
    if ($run->log_file =~ m/\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new(\($run->log_data)) or die "Could not open bz2 data: $Bunzip2Error";
    }
    else {
        $fh = IO::Uncompress::Gunzip->new(\($run->log_data)) or die "Could not open gz data: $GunzipError";
    }

    my $schema = $self->{+CONFIG}->schema;

    local $| = 1;
    my $last = 0;
    while (my $line = <$fh>) {
        my $ord = $.;
        if (time - $last >= 0.1) {
            print "$ord\r";
            $last = time;
        }
        my $error = $@;

        $error = $self->process_event($line);
        $error ||= $self->flush_ready if @{$self->{+READY}};

        return {errors => ["error processing line number $ord: $error"]} if $error;
    }

    $self->flush_all;

    return {success => 1, passed => $self->{+PASSED}, failed => $self->{+FAILED}};
}

sub flush_ready {
    my $self = shift;

    my $jobs = delete $self->{+READY};
    $self->{+READY} = [];

    my @events;

    my $mode = $self->{+MODE};
    for my $job (@$jobs) {
        my $raw = delete $job->{raw_events};

        my $internal = $job->{name} eq 'LOG' ? 1 : 0;

        next if $mode <= $MODES{summary} && !$internal;

        my $fail = $job->{fail};
        next if $mode <= $MODES{qvf} && !$fail && !$internal;

        my $db_id = $job->{job_id};

        my $start = time;
        my $ord   = 0;
        for my $f (@$raw) {
            $f = $self->_facet_data($f) unless ref $f;
            return $f unless ref $f;

            my ($new, $error) = $self->process_facets($f, $job, undef, 0);
            return $error if $error;

            for my $event (@$new) {
                next unless $internal || $fail || $mode > $MODES{qvfd} || $event->{is_diag};

                if ($event->{nested} && $self->{+STORE_ORPHANS} ne 'yes' && !$internal) {
                    next if $self->{+STORE_ORPHANS} eq 'no';

                    # store on fail only
                    next unless $fail;
                }

                delete $event->{is_diag};
                push @events => $event;
            }
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

sub flush_all {
    my $self = shift;

    my $buffer = delete $self->{+BUFFER};

    push @{$self->{+READY}} => values %$buffer;

    $self->flush_ready;
    return;
}

sub _new_job {
    my $self = shift;
    my ($name) = @_;

    my $run = $self->{+RUN};

    return {
        job_id  => Data::GUID->new->as_string,
        job_ord => $self->{+JOB_ORD}++,
        run_id  => $run->run_id,
        name    => $name,

        "$name" eq '0' ? (file => 'HARNESS INTERNAL LOG') : (),
    };
}

sub _facet_data {
    my $self = shift;
    my ($json) = @_;

    my $event_data;
    my $ok = eval { $event_data = decode_json($json) };
    return $@ unless $ok;
    return $event_data->{facet_data};
}

sub process_event {
    my $self = shift;
    my ($json) = @_;

    my $run = $self->{+RUN};
    my $buffer = $self->{+BUFFER} ||= {};

    my $f;
    my $job_name = ($json =~ m/"job_id"\s*:\s*"([^"]+)"/) ? $1 : undef;
    unless (defined($job_name) && length($job_name)) {
        $f = $self->_facet_data($json);
        return $f unless ref $f;
        $job_name = $f->{harness}->{job_id};
        return "No 'job_id'" unless defined $job_name;
    }

    my $job = $buffer->{$job_name} ||= $self->_new_job($job_name);

    unless ($json =~ m/"harness_(?:run|job(?:_(?:start|exit|launch|end))?)"/) {
        push @{$job->{raw_events}} => $f || $json;
        return;
    }

    $f ||= $self->_facet_data($json);
    return $f unless ref $f;

    push @{$job->{raw_events}} => $f;

    # Handle the run event
    if (my $run_data = $f->{harness_run}) {
        $run->update({parameters => encode_json($run_data)});
        $f->{harness_run} = "Removed, see run with run_id " . $run->run_id;
    }

    # Handle job events
    if (my $job_data = $f->{harness_job}) {
        $job->{file} ||= $job_data->{file};
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
        push @{$self->{+READY}} => delete $buffer->{$job_name};
        delete $self->{+CIDS}->{$job->{job_id}};
        delete $self->{+HIDS}->{$job->{job_id}};
    }

    return;
}

sub clean_output {
    my $text = shift;

    return undef unless defined $text;
    $text =~ s/^T2-HARNESS-ESYNC: \d+\n//gm;
    chomp($text);

    return undef unless length($text);
    return $text;
}

sub process_facets {
    my $self = shift;
    my ($f, $job, $parent_db_id, $orphan) = @_;

    my $ord = $self->eord();

    my $db_id = Data::GUID->new->as_string;

    my $is_diag = 0;
    $is_diag ||= $f->{errors} && @{$f->{errors}};
    $is_diag ||= $f->{assert} && !($f->{assert}->{pass} || $f->{amnesty});
    $is_diag ||= grep { $_->{debug} || $_->{important} } @{$f->{info}} if $f->{info};

    my ($nested, $cid, $hid);
    if (my $trace = $f->{trace}) {
        $nested = $trace->{nested} || 0;
        if (length(my $c = $trace->{cid})) {
            $cid = $self->{+CIDS}->{$job->{job_id}}->{$c} ||= Data::GUID->new->as_string;
        }
        if (length(my $h = $trace->{hid})) {
            $hid = $self->{+HIDS}->{$job->{job_id}}->{$h} ||= Data::GUID->new->as_string;
        }
    }
    else {
        $nested = 0;
    }

    $orphan = 1 if $nested && !$parent_db_id;

    my $row = {
        event_id  => $db_id,
        event_ord => $ord,
        job_id    => $job->{job_id},
        parent_id => $parent_db_id,

        hid => $hid,
        cid => $cid,

        nested    => $nested,
        is_parent => 0,
        is_orphan => $orphan,
    };

    my @children;
    if ($f->{parent} && $f->{parent}->{children}) {
        $row->{is_parent} = 1;

        my $cnt = 0;
        for my $child (@{$f->{parent}->{children}}) {
            my ($crows, $error, $diag) = $self->process_facets($child, $job, $db_id, $orphan);
            return (undef, "Error in subevent [$cnt]: $error") if $error || !$crows;

            $is_diag ||= 1 if $diag;
            $cnt++;

            push @children => @$crows;
        }

        $f->{parent}->{children} = "Removed, see events with parent_id $db_id";
    }

    $row->{facets} = encode_json($f);

    if ($self->{+MODE} == $MODES{qvfd} && !$job->{fail} && !$parent_db_id) {
        @children = grep { $_->{is_diag} } @children;
    }

    $row->{is_diag} = $is_diag ? 1 : 0;

    return ([$row, @children], undef, $is_diag);
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
