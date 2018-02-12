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

use Test2::Harness::UI::Util::HashBase qw/-config -run -buffer -ready -job_ord -mode -store_facets -store_orphans/;

use IO::Compress::Bzip2 qw($Bzip2Error);
use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip qw($GunzipError);

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

    my $mode = $self->{+RUN}->mode;
    $self->{+MODE} = $MODES{$mode} or croak "Invalid mode '$mode'";

    $self->{+STORE_FACETS}  = $self->{+RUN}->store_facets;
    $self->{+STORE_ORPHANS} = $self->{+RUN}->store_orphans;
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

    my $log_data;
    my $bz2 = IO::Compress::Bzip2->new(\$log_data) or die "IO::Compress::Bzip2 failed: $Bzip2Error";

    local $| = 1;
    my $last = 0;
    while (my $line = <$fh>) {
        my $ord = $.;
        if (time - $last >= 0.1) {
            print "$ord\r";
            $last = time;
        }
        my $error = $@;

        $error = $self->process_event($ord, $line);
        $error ||= $self->flush_ready if @{$self->{+READY}};

        return {errors => ["error processing line number $ord: $error"]} if $error;
        $bz2->write($line);
    }

    $self->flush_all;

    $run->update({log_data => $log_data});

    return {success => 1};
}

sub flush_ready {
    my $self = shift;

    my $jobs = delete $self->{+READY};
    $self->{+READY} = [];

    my @events;
    my @event_lines;

    my $mode = $self->{+MODE};
    for my $job (@$jobs) {
        my $raw = delete $job->{raw_events};

        my $internal = $job->{name} eq 'INTERNAL' ? 1 : 0;

        next if $mode <= $MODES{summary} && !$internal;

        my $fail = $job->{fail};
        next if $mode <= $MODES{qvf} && !$fail && !$internal;

        my $db_id = $job->{job_id};

        my $start = time;
        my $ord   = 0;
        for my $f (@$raw) {
            $f = $self->_facet_data($f) unless ref $f;
            return $f unless ref $f;

            my ($new, $error) = $self->process_facets($ord++, $f, $job);
            return $error if $error;

            for my $event (@$new) {
                next unless $internal || $fail || $mode > $MODES{qvfd} || $event->{is_diag};

                if ($event->{nested} && $self->{+STORE_ORPHANS} ne 'yes' && !$internal) {
                    next if $self->{+STORE_ORPHANS} eq 'no';

                    # store on fail only
                    next unless $fail;
                }

                push @events      => $event;
                push @event_lines => @{$self->render_event($event)};
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
        $schema->resultset('EventLine')->populate(\@event_lines);
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

    $name = 'INTERNAL' if "$name" eq '0';

    return {
        job_id  => Data::GUID->new->as_string,
        job_ord => $self->{+JOB_ORD}++,
        run_id  => $run->run_id,
        name    => $name,
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
    my ($ord, $json) = @_;

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

        # All done
        push @{$self->{+READY}} => delete $buffer->{$job_name};
    }

    return;
}

sub process_facets {
    my $self = shift;
    my ($ord, $f, $job, $parent_db_id) = @_;

    my $db_id = Data::GUID->new->as_string;

    my $is_diag = 0;
    $is_diag ||= $f->{errors} && @{$f->{errors}};
    $is_diag ||= $f->{assert} && !($f->{assert}->{pass} || $f->{amnesty});
    $is_diag ||= grep { $_->{debug} || $_->{important} } @{$f->{info}} if $f->{info};

    my $nested = $f->{trace} ? ($f->{trace}->{nested} || 0) : 0;

    my $row = {
        f         => $f,
        event_id  => $db_id,
        event_ord => $ord,
        job_id    => $job->{job_id},
        parent_id => $parent_db_id,

        nested      => $nested,
        causes_fail => causes_fail($f) ? 1 : 0,

        no_render  => $f->{harness_watcher} && $f->{harness_watcher}->{no_render} ? 1 : 0,
        no_display => $f->{about}           && $f->{about}->{no_display}          ? 1 : 0,
        is_orphan  => $nested               && !$parent_db_id                     ? 1 : 0,

        is_parent => $f->{parent} ? 1 : 0,
        is_assert => $f->{assert} ? 1 : 0,
        is_plan   => $f->{plan}   ? 1 : 0,

        assert_pass => $f->{assert} ? $f->{assert}->{pass} : undef,
        plan_count  => $f->{plan}   ? $f->{plan}->{count}  : undef,
    };

    my @children;
    if ($f->{parent} && $f->{parent}->{children}) {
        my $cnt = 0;
        for my $child (@{$f->{parent}->{children}}) {
            my ($crows, $error, $diag) = $self->process_facets($cnt, $child, $job, $db_id);
            return (undef, "Error in subevent [$cnt]: $error") if $error || !$crows;

            $is_diag ||= 1 if $diag;
            $cnt++;

            push @children => @$crows;
        }

        $f->{parent}->{children} = "Removed, see events with parent_id $db_id";
    }

    $row->{facets} = encode_json($f) if $self->{+STORE_FACETS} eq 'yes' || ($self->{+STORE_FACETS} eq 'fail' && $job->{fail});

    if ($self->{+MODE} == $MODES{qvfd} && !$job->{fail} && !$parent_db_id) {
        @children = grep { $_->{is_diag} } @children;
    }

    $row->{is_diag} = $is_diag ? 1 : 0;

    return ([$row, @children], undef, $is_diag);
}

sub render_event {
    my $self = shift;
    my ($event, $out) = @_;

    my $f = delete $event->{f};

    my $got = Test2::Formatter::Test2::Composer->render_verbose($f);

    $out ||= [];
    $self->render_event($_, $out) for @{$event->{events} || []};

    for my $line (@$got) {
        my ($facet, $tag, $data) = @$line;

        my ($content, $content_json);

        if (ref($data)) {
            $content = encode_json($data);
        }
        else {
            $content = $data;
        }

        push @$out => {
            event_id     => $event->{event_id},
            facet        => $facet,
            tag          => $tag,
            content      => $content,
            content_json => $content_json,
        };
    }

    return $out;
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
