package Test2::Harness::UI::RunProcessor;
use strict;
use warnings;

our $VERSION = '0.000099';

use DateTime;
use Data::GUID;
use Time::HiRes qw/time/;
use List::Util qw/first min max/;
use Data::Dumper qw/Dumper/;

use Clone qw/clone/;
use Carp qw/croak confess/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use JSON::PP();

use Test2::Harness::UI::Util::ImportModes qw{
    %MODES
    record_all_events
    event_in_mode
    mode_check
};

use Test2::Harness::UI::Util::HashBase qw{
    <config

    <running <jobs

    signal

    <coverage <uncover <new_jobs <id_cache <file_cache

    <mode
    <interval <last_flush
    <run <run_id
    +user +user_id
    +project +project_id

    <first_stamp <last_stamp

    <passed <failed <retried
    <job0_id <job_ord
};

sub format_stamp {
    my $self = shift;
    my $stamp = shift;
    return undef unless $stamp;

    unless (ref($stamp)) {
        $self->{+FIRST_STAMP} = $self->{+FIRST_STAMP} ? min($self->{+FIRST_STAMP}, $stamp) : $stamp;
        $self->{+LAST_STAMP}  = $self->{+LAST_STAMP}  ? max($self->{+LAST_STAMP}, $stamp)  : $stamp;
    }

    return DateTime->from_epoch(epoch => $stamp, time_zone => 'local');
}

sub schema { $_[0]->{+CONFIG}->schema }

sub init {
    my $self = shift;

    croak "'config' is a required attribute"
        unless $self->{+CONFIG};

    my $run;
    if ($run = $self->{+RUN}) {
        $self->{+RUN_ID} = $run->run_id;
        $self->{+MODE}   = $MODES{$run->mode};

        eval { $run->update({status => 'pending'}); 1 } || warn "Failed to update status for run '$self->{+RUN_ID}': $@";
    }
    else {
        my $run_id = $self->{+RUN_ID} // croak "either 'run' or 'run_id' must be provided";
        my $mode   = $self->{+MODE}   // croak "'mode' is a required attribute unless 'run' is specified";
        $self->{+MODE} = $MODES{$mode} // croak "Invalid mode '$mode'";

        my $schema = $self->schema;
        my $run = $schema->resultset('Run')->create({
            run_id     => $run_id,
            user_id    => $self->user_id,
            project_id => $self->project_id,
            mode       => $mode,
            status     => 'pending',
        });

        $self->{+RUN} = $run;
    }

    $self->{+ID_CACHE} = {};
    $self->{+COVERAGE} = [];

    $self->{+PASSED} = 0;
    $self->{+FAILED} = 0;

    $self->{+JOB_ORD} = 1;
    $self->{+JOB0_ID} = gen_uuid();
}

sub flush_all {
    my $self = shift;

    my $all = $self->{+JOBS};
    for my $jobs (values %$all) {
        for my $job (values %$jobs) {
            $job->{done} = 'end';
            $self->flush(job => $job);
        }
    }

    $self->flush_events();
}

sub flush {
    my $self = shift;
    my %params = @_;

    my $job = $params{job} or croak "job is required";
    my $res = $job->{result};

    my $bmode = $self->run->buffer;
    my $int = $self->{+INTERVAL};

    # Always update if needed
    eval { $self->run->insert_or_update(); 1} or warn "Failed to update run: $@";

    my $flush = $params{force} ? 'force' : 0;
    $flush ||= 'always' if $bmode eq 'none';
    $flush ||= 'diag' if $bmode eq 'diag' && $res->fail && $params{is_diag};
    $flush ||= 'job' if $job->{done};
    $flush ||= 'status' if $res->is_column_changed('status');
    $flush ||= 'fail' if $res->is_column_changed('fail');

    if ($int && !$flush) {
        my $last = $self->{+LAST_FLUSH};
        $flush = 'interval' if !$last || $int < time - $last;
    }

    return "" unless $flush;
    $self->{+LAST_FLUSH} = time;

    eval { $res->update(); 1 } or warn "Failed to update job result: $@";

    $self->flush_events();

    if (my $done = $job->{done}) {
        # Last time we need to write this, so clear it.
        delete $self->{+JOBS}->{$job->{job_id}}->{$job->{job_try}};

        unless ($res->status eq 'complete') {
            my $status = $self->{+SIGNAL} ? 'canceled' : 'broken';
            $status = 'canceled' if $done eq 'end';
            $res->status($status)
        }

        # Normalize the fail/pass
        my $fail = $res->fail ? 1 : 0;
        $res->fail($fail);

        $res->normalize_to_mode(mode => $self->{+MODE});
    }

    eval { $res->update(); 1 } or warn "Failed to update job result: $@";

    return $flush;
}

my $total = 0;
sub flush_events {
    my $self = shift;

    return if mode_check($self->{+MODE}, 'summary');

    my @write;

    my $jobs = $self->{+JOBS};
    for my $tries (values %$jobs) {
        for my $job (values %$tries) {
            my $events = $job->{events};
            my $deferred = $job->{deffered_events} //= [];

            if (record_all_events(mode => $self->{+MODE}, job => $job->{result})) {
                push @write => (@$deferred, @$events);
                @$deferred = ();
            }
            else {
                for my $event (@$events) {
                    if (event_in_mode(event => $event, record_all_event => 0, mode => $self->{+MODE}, job => $job->{result})) {
                        push @write => $event;
                    }
                    else {
                        push @$deferred => $event;
                    }
                }
            }

            @$events = ();
        }
    }

    return unless @write;

    local $ENV{DBIC_DT_SEARCH_OK} = 1;
    unless (eval { $self->schema->resultset('Event')->populate(\@write); 1 }) {
        warn "Failed to populate events!\n$@\n" . Dumper(\@write);
    }
    $total += scalar(@write);
}

sub user {
    my $self = shift;

    return $self->{+RUN}->user if $self->{+RUN};
    return $self->{+USER} if $self->{+USER};

    my $user_id = $self->{+USER_ID} // confess "No user or user_id specified";

    my $schema = $self->schema;
    my $user = $schema->resultset('Run')->search({user_id => $user_id})->first;
    return $user if $user;
    confess "Invalid user_id: $user_id";
}

sub user_id {
    my $self = shift;

    return $self->{+RUN}->user_id if $self->{+RUN};
    return $self->{+USER}->user_id if $self->{+USER};
    return $self->{+USER_ID} if $self->{+USER_ID};
}

sub project {
    my $self = shift;

    return $self->{+RUN}->project if $self->{+RUN};
    return $self->{+PROJECT} if $self->{+PROJECT};

    my $project_id = $self->{+PROJECT_ID} // confess "No project or project_id specified";

    my $schema = $self->schema;
    my $project = $schema->resultset('Project')->search({project_id => $project_id})->first;
    return $project if $project;
    confess "Invalid project_id: $project_id";
}

sub project_id {
    my $self = shift;

    return $self->{+RUN}->project_id if $self->{+RUN};
    return $self->{+PROJECT}->project_id if $self->{+PROJECT};
    return $self->{+PROJECT_ID} if $self->{+PROJECT_ID};
}

sub start {
    my $self = shift;
    return if $self->{+RUNNING};

    eval {$self->{+RUN}->update({status => 'running'}); 1 } or warn "Failed to update status: $@";

    $self->{+RUNNING} = 1;
}

sub get_job {
    my $self = shift;
    my (%params) = @_;

    my $is_harness_out = 0;
    my $job_id = $params{job_id};

    if (!$job_id || $job_id eq '0') {
        $job_id = $self->{+JOB0_ID};
        $is_harness_out = 1;
    }

    my $job_try = $params{job_try} // 0;

    my $job = $self->{+JOBS}->{$job_id}->{$job_try};
    return $job if $job;

    my $key = gen_uuid();

    my $test_file_id = undef;
    if (my $queue = $params{queue}) {
        my $file = $queue->{rel_file} // $queue->{file};
        $test_file_id = $self->get_test_file_id($file) if $file;
        $self->{+FILE_CACHE}->{$job_id} //= $test_file_id if $test_file_id;
    }

    $test_file_id //= $self->{+FILE_CACHE}->{$job_id};

    my $result = $self->schema->resultset('Job')->update_or_create({
        status         => 'pending',
        job_key        => $key,
        job_id         => $job_id,
        job_try        => $job_try,
        is_harness_out => $is_harness_out,
        job_ord        => $self->{+JOB_ORD}++,
        run_id         => $self->{+RUN}->run_id,
        fail_count     => 0,
        pass_count     => 0,
        test_file_id   => $test_file_id,

        $is_harness_out ? (name => "HARNESS INTERNAL LOG") : (),
    });

    # In case we are resuming.
    $result->events->delete_all();

    # Prevent duplicate coverage when --retry is used
    $self->schema->resultset('Coverage')->search({'job_key.job_id' => $job_id}, {join => 'job_key'})->delete if $job_try;
    if (my $old = $self->{+JOBS}->{$job_id}->{$job_try - 1}) {
        $self->{+UNCOVER}->{$old->{job_key}}++;
    }

    $job = {
        job_key => $key,
        job_id  => $job_id,
        job_try => $job_try,

        events  => [],
        orphans => {},

        event_ord => 1,
        result    => $result,
    };

    return $self->{+JOBS}->{$job_id}->{$job_try} = $job;
}

sub process_event {
    my $self = shift;
    my ($event, $f, %params) = @_;

    $f //= $event->{facet_data};
    $f = $f ? clone($f) : {};

    $self->start unless $self->{+RUNNING};

    my $job = $params{job} // $self->get_job(%{$f->{harness} // {}}, queue => $f->{harness_job_queued});

    my $e = $self->_process_event($event, $f, %params, job => $job);
    clean($e);

    if (my $od = $e->{orphan}) {
        $job->{orphans}->{$e->{event_id}} = $e;
    }
    else {
        if (my $o = delete $job->{orphans}->{$e->{event_id}}) {
            $e->{orphan} = $o->{orphan};
            $e->{orphan_line} = $o->{orphan_line} if defined $o->{orphan_line};
        }
        push @{$job->{events}} => $e;
    }

    $self->flush(job => $job, is_diag => $e->{is_diag});

    return;
}

sub format_duration {
    my $seconds = shift;

    my $minutes = int($seconds / 60);
    my $hours   = int($minutes / 60);
    my $days    = int($hours / 24);

    $minutes %= 60;
    $hours   %= 24;

    $seconds -= $minutes * 60;
    $seconds -= $hours * 60 * 60;
    $seconds -= $days * 60 * 60 * 24;

    my @dur;
    push @dur => sprintf("%02dd", $days) if $days;
    push @dur => sprintf("%02dh", $hours) if @dur || $hours;
    push @dur => sprintf("%02dm", $minutes) if @dur || $minutes;
    push @dur => sprintf("%07.4fs", $seconds);

    return join ':' => @dur;
}

sub finish {
    my $self = shift;
    my (@errors) = @_;

    $self->flush_all();

    my $run = $self->run;

    my $status;

    if (@errors) {
        my $error = join "\n" => @errors;
        $status = {status => 'broken', error => $error};
    }
    else {
        my $stat = $self->{+SIGNAL} ? 'canceled' : 'complete';
        $status = {status => $stat, passed => $self->{+PASSED}, failed => $self->{+FAILED}, retried => $self->{+RETRIED}};
    }

    if ($self->{+FIRST_STAMP} && $self->{+LAST_STAMP}) {
        $status->{duration} = format_duration($self->{+LAST_STAMP} - $self->{+FIRST_STAMP});
    }

    eval { $run->update($status); 1 } or warn "Failed to update run status: $@";

    return $status;
}

sub _process_event {
    my $self = shift;
    my ($event, $f, %params) = @_;
    my $job = $params{job};

    my $harness = $f->{harness} // {};
    my $trace   = $f->{trace}   // {};

    my $e_id   = $harness->{event_id} // $event->{event_id} // die "No event id!";
    my $nested = $f->{hubs}->[0]->{nested} || 0;

    my $fail = causes_fail($f) ? 1 : 0;

    my $is_diag = $fail;
    $is_diag ||= 1 if $f->{errors} && @{$f->{errors}};
    $is_diag ||= 1 if $f->{assert} && !($f->{assert}->{pass} || $f->{amnesty});
    $is_diag ||= 1 if $f->{info} && first { $_->{debug} || $_->{important} } @{$f->{info}};
    $is_diag //= 0;

    my $is_harness = (first { substr($_, 0, 8) eq 'harness_' } keys %$f) ? 1 : 0;

    my $is_time = $f->{harness_job_end} ? ($f->{harness_job_end}->{times} ? 1 : 0) : 0;

    my $is_subtest = $f->{parent} ? 1 : 0;

    my $e = {
        event_id   => $e_id,
        nested     => $nested,
        is_subtest => $is_subtest,
        is_diag    => $is_diag,
        is_harness => $is_harness,
        is_time    => $is_time,
        trace_id   => $trace->{uuid},
        job_key    => $job->{job_key},
        event_ord  => $job->{event_ord}++,
        stamp      => $self->format_stamp($harness->{stamp} || $event->{stamp} || $params{stamp}),
    };

    my $orphan = $nested ? 1 : 0;
    if (my $p = $params{parent_id}) {
        $e->{parent_id} ||= $p;
        $orphan = 0;
    }

    if ($orphan) {
        clean($f);

        if ($f->{parent} && $f->{parent}->{children}) {
            $f->{parent}->{children} = "Removed";
        }

        $e->{orphan}      = encode_json($f);
        $e->{orphan_line} = $params{line} if $params{line};
    }
    else {
        if (my $fields = $f->{run_fields}) {
            $self->add_run_fields($fields);
        }

        if (my $job_coverage = $f->{job_coverage}) {
            $self->add_job_coverage($job, $job_coverage);
            $f->{job_coverage} = "Removed, used to populate the job_coverage table";
        }

        if (my $run_coverage = $f->{run_coverage}) {
            $f->{run_coverage} = "Removed, used to populate the run_coverage table";
            $self->add_run_coverage($run_coverage);
        }

        if ($f->{parent} && $f->{parent}->{children}) {
            $self->process_event({}, $_, job => $job, parent_id => $e_id, line => $params{line}) for @{$f->{parent}->{children}};
            $f->{parent}->{children} = "Removed, used to populate events table";
        }

        unless ($nested) {
            my $res = $job->{result};
            if ($fail) {
                $res->fail_count($res->fail_count + 1);
                $res->fail(1);
            }
            $res->pass_count($res->pass_count + 1) if $f->{assert} && !$fail;

            $self->update_other($job, $f) if $e->{is_harness};
        }

        clean($f);
        $e->{facets}      = encode_json($f);
        $e->{facets_line} = $params{line} if $params{line};
    }

    return $e;
}

sub add_job_coverage {
    my $self = shift;
    my ($job, $job_coverage) = @_;

    my $job_id  = $job->{job_id};
    my $job_try = $job->{job_try} // 0;

    # Do not add coverage if a retry has already started. Events could be out of order.
    return if $self->{+JOBS}->{$job_id}->{$job_try + 1};
    return if $self->{+UNCOVER} && $self->{+UNCOVER}->{$job->{job_key}};

    for my $source (keys %{$job_coverage->{files}}) {
        my $subs = $job_coverage->{files}->{$source};
        for my $sub (keys %$subs) {
            $self->_add_coverage(
                job_key => $job->{job_key},
                test    => $job_coverage->{test} // $job->{result}->file,
                source  => $source,
                sub     => $sub,
                manager => $job_coverage->{manager},
                meta    => $subs->{$sub},
            );
        }
    }

    $self->flush_coverage;
}

sub add_run_coverage {
    my $self = shift;
    my ($run_coverage) = @_;

    my $files = $run_coverage->{files};
    my $meta  = $run_coverage->{testmeta};

    for my $source (keys %$files) {
        my $subs = $files->{$source};
        for my $sub (keys %$subs) {
            my $tests = $subs->{$sub};
            for my $test (keys %$tests) {
                $self->_add_coverage(
                    test    => $test,
                    source  => $source,
                    sub     => $sub,
                    manager => $meta->{$test}->{manager},
                    meta    => $tests->{$test}
                );
            }
        }
    }

    $self->flush_coverage;
}

sub _add_coverage {
    my $self = shift;
    my %params = @_;

    my $test_id = $self->get_test_file_id($params{test}) or confess("Could not get test id (for '$params{test}')");

    my $source_id  = $self->_get__id(SourceFile      => 'source_file_id',      filename => $params{source}) or die "Could not get source id";
    my $sub_id     = $self->_get__id(SourceSub       => 'source_sub_id',       subname  => $params{sub})    or die "Could not get sub id";
    my $manager_id = $self->_get__id(CoverageManager => 'coverage_manager_id', package  => $params{manager});

    my $meta = $manager_id ? encode_json($params{meta}) : undef;

    my $coverage = $self->{+COVERAGE} //= [];

    push @$coverage => {
        coverage_id         => gen_uuid(),
        run_id              => $self->{+RUN_ID},
        test_file_id        => $test_id,
        source_file_id      => $source_id,
        source_sub_id       => $sub_id,
        coverage_manager_id => $manager_id,
        metadata            => $meta,
        job_key             => $params{job_key},
    };
}

sub flush_coverage {
    my $self = shift;

    my $coverage = $self->{+COVERAGE} or return;
    return unless @$coverage;

    $self->{+RUN}->update({has_coverage => 1}) unless $self->{+RUN}->has_coverage;
    $self->schema->resultset('Coverage')->populate($coverage);

    @$coverage = ();

    return;
}

sub _get__id {
    my $self = shift;
    my ($type, $id_field, $field, $id) = @_;

    return undef unless $id;

    return $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id}
        if $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id};

    my $spec = {$field => $id, $id_field => gen_uuid()};
    my $result = $self->schema->resultset($type)->find_or_create($spec);

    return $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id} = $result->$id_field;
}

sub get_test_file_id {
    my $self = shift;
    my ($file) = @_;

    return undef unless $file;

    return $self->_get__id('TestFile' => 'test_file_id', filename => $file);
}

sub add_run_fields {
    my $self = shift;
    my ($fields) = @_;

    my $run    = $self->{+RUN};
    my $run_id = $run->run_id;

    return $self->_add_fields(
        fields    => $fields,
        type      => 'RunField',
        key_field => 'run_field_id',
        attrs     => {run_id => $run_id},
    );
}

sub add_job_fields {
    my $self = shift;
    my ($job, $fields) = @_;

    my $job_key = $job->job_key;

    return $self->_add_fields(
        fields    => $fields,
        type      => 'JobField',
        key_field => 'job_field_id',
        attrs     => {job_key => $job_key},
    );
}

sub _add_fields {
    my $self = shift;
    my %params = @_;

    my $fields    = $params{fields};
    my $type      = $params{type};
    my $key_field = $params{key_field};
    my $attrs     = $params{attrs} // {};

    my @add;
    for my $field (@$fields) {
        my $id  = gen_uuid;
        my $new = {%$attrs, $key_field => $id};

        $new->{name}    = $field->{name}    || 'unknown';
        $new->{details} = $field->{details} || $new->{name};
        $new->{raw}     = $field->{raw}               if $field->{raw};
        $new->{link}    = $field->{link}              if $field->{link};
        $new->{data}    = encode_json($field->{data}) if $field->{data};


        push @add => $new;

        # Replace the item in the $fields array with the id
        $field = $id;
    }

    $self->schema->resultset($type)->populate(\@add);
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

sub update_other {
    my $self = shift;
    my ($job, $f) = @_;

    my $run = $self->{+RUN};

    if (my $run_data = $f->{harness_run}) {
        my $settings = $run_data->{settings} //= $f->{harness_settings};

        if (my $j = $settings->{runner}->{job_count}) {
            $run->concurrency($j);
        }

        clean($run_data);
        $run->parameters($run_data);

        if (my $fields = $run_data->{harness_run_fields} // $run_data->{fields}) {
            $self->add_run_fields($fields);
        }
    }

    my $job_result = $job->{result};
    my %cols = $job_result->get_columns;

    # Handle job events
    if (my $job_data = $f->{harness_job}) {
        #$cols{test_file_id} ||= $self->get_test_file_id($job_data->{file});
        $cols{name} ||= $job_data->{job_name};
        clean($job_data);
        $cols{parameters} = encode_json($job_data);
        $f->{harness_job}  = "Removed, see job with job_key $cols{job_key}";
    }
    if (my $job_exit = $f->{harness_job_exit}) {
        #$cols{test_file_id} ||= $self->get_test_file_id($job_exit->{file});
        $cols{exit_code} = $job_exit->{exit};

        if ($job_exit->{retry} && $job_exit->{retry} eq 'will-retry') {
            $cols{retry} = 1;
            $self->{+RETRIED}++;
            $self->{+FAILED}--;
        }
        else {
            $cols{retry} = 0;
        }

        $cols{stderr} = clean_output(delete $job_exit->{stderr});
        $cols{stdout} = clean_output(delete $job_exit->{stdout});
    }
    if (my $job_start = $f->{harness_job_start}) {
        $cols{test_file_id} ||= $self->get_test_file_id($job_start->{rel_file}) if $job_start->{rel_file};
        $cols{test_file_id} ||= $self->get_test_file_id($job_start->{file});
        $cols{start} = $self->format_stamp($job_start->{stamp});
    }
    if (my $job_launch = $f->{harness_job_launch}) {
        $cols{status} = 'running';

        $cols{test_file_id} ||= $self->get_test_file_id($job_launch->{file});
        $cols{launch} = $self->format_stamp($job_launch->{stamp});
    }
    if (my $job_end = $f->{harness_job_end}) {
        #$cols{test_file_id} ||= $self->get_test_file_id($job_end->{file});
        $cols{fail} ||= $job_end->{fail} ? 1 : 0;
        $cols{ended} = $self->format_stamp($job_end->{stamp});

        $cols{fail} ? $self->{+FAILED}++ : $self->{+PASSED}++;

        # All done
        $job->{done} = 1;

        if ($job_end->{rel_file} && $job_end->{times} && $job_end->{times}->{totals} && $job_end->{times}->{totals}->{total}) {
            $cols{test_file_id} ||= $self->get_test_file_id($job_end->{rel_file}) if $job_end->{rel_file};
            $cols{duration} = $job_end->{times}->{totals}->{total};
        }
    }
    if (my $job_fields = $f->{harness_job_fields}) {
        $self->add_job_fields($job_result, $job_fields);
    }

    $job_result->set_columns(\%cols);

    return;
}

1;

__END__


        if ($new->{name} eq 'coverage' && !$new->{link} && $type eq 'RunField') {
            $new->{link} = "/coverage/$id";
        }
=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Import

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
