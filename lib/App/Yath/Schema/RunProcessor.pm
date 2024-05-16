package App::Yath::Schema::RunProcessor;
use strict;
use warnings;

our $VERSION = '2.000000';

use DateTime;
use Data::Dumper;

use List::Util qw/first min max/;
use Time::HiRes qw/time sleep/;
use MIME::Base64 qw/decode_base64/;
use Sys::Hostname qw/hostname/;

use Clone qw/clone/;
use Carp qw/croak confess/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use App::Yath::Schema::Config;

use App::Yath::Schema::Util qw/format_duration is_invalid_subtest_name schema_config_from_settings/;
use App::Yath::Schema::UUID qw/gen_uuid uuid_inflate uuid_deflate uuid_mass_deflate/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use App::Yath::Schema::ImportModes qw{
    %MODES
    record_all_events
    event_in_mode
    mode_check
    record_subtest_events
};

use Test2::Harness::Util::HashBase qw{
    <config

    <running <jobs

    signal

    <coverage <uncover <new_jobs <id_cache <file_cache

    <mode
    <interval <last_flush
    <run <run_id
    +user +user_idx
    +project +project_idx

    <first_stamp <last_stamp

    <passed <failed <retried
    <job0_id

    <disconnect_retry

    +host
};

sub process_stdin {
    my $class = shift;
    my ($settings) = @_;

    return $class->process_handle(\*STDIN, $settings);
}


sub process_handle {
    my $class = shift;
    my ($fh, $settings) = @_;

    my $cb = $class->process_lines($settings);

    while (my $line = <$fh>) {
        $cb->($line);
    }
}

sub process_lines {
    my $class = shift;
    my ($settings, %params) = @_;

    my $done = 0;
    my ($next, $last, $run);
    return sub {
        my $line = shift;

        croak "Call to process lines callback after an undef line" if $done;

        if (!defined($line)) {
            $done++;
            $last->();
        }
        elsif ($next) {
            $next->($line);
        }
        else {
            ($next, $last, $run) = $class->_process_first_line($line, $settings, %params);
        }

        return $run;
    };
}

sub _process_first_line {
    my $class = shift;
    my ($line, $settings, %params) = @_;

    my $run;
    my $config = schema_config_from_settings($settings);
    my $dbh = $config->connect // die "Could not connect to the db";

    {
        no warnings 'once';
        $dbh->{mysql_auto_reconnect} = 1 if $App::Yath::Schema::LOADED =~ m/(mysql|percona|maraidb)/i;
    }

    my $e = decode_json(scalar $line);
    my $f = $e->{facet_data};

    my $self;
    my $run_id;
    if (my $runf = $f->{harness_run}) {
        $run_id = uuid_inflate($runf->{run_id}) or die "No run-id?";

        my $pub = $settings->group('publish') or die "No publish settings";

        my $proj = $runf->{settings}->{yath}->{project} || $params{project} || $settings->yath->project or die "Project name could not be determined";
        my $user = $settings->yath->user // $ENV{USER};

        my $p = $config->schema->resultset('Project')->find_or_create({name => $proj});
        my $u = $config->schema->resultset('User')->find_or_create({username => $user, role => 'user'});

        if (my $old = $config->schema->resultset('Run')->find({run_id => $run_id})) {
            die "Run with id '$run_id' is already published. Use --publish-force to override it." unless $settings->publish->force;
            $old->delete;
        }

        $run = $config->schema->resultset('Run')->create({
            run_id     => $run_id,
            mode       => $pub->mode,
            buffer     => $pub->buffering,
            status     => 'pending',
            user_idx    => $u->user_idx,
            project_idx => $p->project_idx,
        });

        $self = $class->new(
            settings => $settings,
            config => $config,
            run => $run,
            interval => $pub->flush_interval,
        );

        $self->start();
        $self->process_event($e, $f);
    }
    else {
        die "First event did not contain run data";
    }

    my $links;
    if ($settings->check_group('webclient')) {
        if (my $url = $settings->webclient->url) {
            $links = "\nThis run can be reviewed at: $url/view/$run_id\n\n";
            print STDOUT $links;
        }
    }

    my $int = $SIG{INT};
    my $term = $SIG{TERM};

    $SIG{INT}  = sub { $self->set_signal('INT');  die "Caught Signal 'INT'\n"; };
    $SIG{TERM} = sub { $self->set_signal('TERM'); die "Caught Signal 'TERM'\n"; };

    my @errors;

    return (
        sub {
            my $line = shift;

            return if eval {
                my $e = decode_json($line);
                $self->process_event($e);
                1;
            };
            my $err = $@;

            warn "Error sending event(s) to database:\n====\n$err\n====\n";

            push @errors => $err;
            die $err if $self->{+SIGNAL};
        },
        sub {
            $self->finish(@errors);
            print STDOUT $links if $links;

            $SIG{INT} = $int;
            $SIG{TERM} = $term;
        },
        $run,
    );
}

sub retry_on_disconnect {
    my $self = shift;
    my ($description, $callback) = @_;

    my ($attempt, $err);
    for my $i (0 .. ($self->{+DISCONNECT_RETRY} - 1)) {
        $attempt = $i;
        return 1 if eval { $callback->(); 1 };
        $err = $@;

        last unless $err =~ m/(gone away|connect|timeout)/i;

        if ($attempt) {
            $self->schema->storage->disconnect;
            sleep 0.5;
        }

        # Try to fix the connection
        $self->schema->storage->ensure_connected();
    }

    die qq{Failed "$description" (attempt $attempt)\n$err\n};
}

sub populate {
    my $self = shift;
    my ($type, $data) = @_;

    return unless $data && @$data;

    $self->retry_on_disconnect(
        "Populate '$type'",
        sub {
            no warnings 'once';
            local $Data::Dumper::Freezer = 'T2HarnessFREEZE';
            local *DateTime::T2HarnessFREEZE = sub { my $x = $_[0]->ymd . " " . $_[0]->hms; $_[0] = \$x };
            my $rs = $self->schema->resultset($type);
            my $ok = eval { $rs->populate($data); 1 };
            my $err = $@;
            return 1 if $ok;

            die $err unless $err =~ m/duplicate/i;

            warn "\nDuplicate found:\n====\n$err\n====\n\nPopulating '$type' 1 at a time.\n";
            for my $item (@$data) {
                uuid_mass_deflate($item);
                next if eval { $rs->create($item); 1 };
                my $err = $@;

                # I need to track down why we still get duplicates (Coverage mainly) for now skip them.
                next if $err =~ m/duplicate/i;

                # Actual error
                warn $err;
            }

            return 1;
        }
    );
}

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

    $self->{+DISCONNECT_RETRY} //= 15;

    my $run;
    if ($run = $self->{+RUN}) {
        $self->{+RUN_ID} = $run->run_id;
        $self->{+MODE}   = $MODES{$run->mode};

        $self->retry_on_disconnect("update status for run '$self->{+RUN_ID}'" => sub { $run->update({status => 'pending'}) });
    }
    else {
        my $run_id = $self->{+RUN_ID} // croak "either 'run' or 'run_id' must be provided";
        my $mode   = $self->{+MODE}   // croak "'mode' is a required attribute unless 'run' is specified";
        $self->{+MODE} = $MODES{$mode} // croak "Invalid mode '$mode'";

        my $schema = $self->schema;
        my $run = $schema->resultset('Run')->create({
            run_id     => $run_id,
            user_idx    => $self->user_idx,
            project_idx => $self->project_idx,
            mode       => $mode,
            status     => 'pending',
        });

        $self->{+RUN} = $run;
    }

    $run->discard_changes;

    $self->{+PROJECT_IDX} //= $run->project_idx;

    confess "No project idx?!?" unless $self->{+PROJECT_IDX};

    $self->{+RUN_ID}     = uuid_inflate($self->{+RUN_ID});
    $self->{+USER_IDX}    = uuid_inflate($self->{+USER_IDX});
    $self->{+PROJECT_IDX} = uuid_inflate($self->{+PROJECT_IDX});

    $self->{+ID_CACHE} = {};
    $self->{+COVERAGE} = [];

    $self->{+PASSED} = 0;
    $self->{+FAILED} = 0;

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
    $self->flush_reporting();
}

sub flush {
    my $self = shift;
    my %params = @_;

    my $job = $params{job} or croak "job is required";
    my $res = $job->{result};

    my $bmode = $self->run->buffer;
    my $int = $self->{+INTERVAL};

    # Always update if needed
    $self->retry_on_disconnect("update run" => sub { $self->run->insert_or_update() });

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

    $self->retry_on_disconnect("update job result" => sub { $res->update() });

    $self->flush_events();
    $self->flush_reporting();

    if (my $done = $job->{done}) {
        # Last time we need to write this, so clear it.
        delete $self->{+JOBS}->{$job->{job_id}}->{$job->{job_try}};

        unless ($res->status eq 'complete') {
            my $status = $self->{+SIGNAL} ? 'canceled' : 'broken';
            $status = 'canceled' if $done eq 'end';
            $res->status($status);
        }

        # Normalize the fail/pass
        my $fail = $res->fail ? 1 : 0;
        $res->fail($fail);

        $res->normalize_to_mode(mode => $self->{+MODE});
    }

    $self->retry_on_disconnect("update job result" => sub { $res->update() });

    return $flush;
}

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

    my @dups;
    my @write_bin;
    my @write_facets;
    my @write_orphans;
    my @write_render;

    for my $e (@write) {
        if (my $bins = delete $e->{binaries}) {
            push @write_bin => @$bins;
        }

        for my $t (qw/facets orphan/) {
            my $l = "${t}_line";
            my $list = $t eq 'facets' ? \@write_facets : \@write_orphans;

            if (my $data = delete $e->{$t}) {
                $e->{"has_$t"} = 1;
                my $line = delete $e->{$l};
                push @$list => {
                    event_id => $e->{event_id},
                    line => $line,
                    data => $data,
                };

                next unless $t eq 'facets';

                my $facets = decode_json($data);

                $e->{is_assert} = $facets->{assert} ? 1 : 0;

                my $lines = App::Yath::Renderer::Default::Composer->render_super_verbose($facets) or next;
                next unless @$lines;

                push @write_render => {
                    event_id => $e->{event_id},
                    data => encode_json($lines),
                };
            }
            else {
                $e->{"has_$t"} = 0;
                delete $e->{$l};
            }
        }
    }

    local $ENV{DBIC_DT_SEARCH_OK} = 1;
    $self->populate(Event  => \@write);
    $self->populate(Render => \@write_render);
    $self->populate(Facet  => \@write_facets);
    $self->populate(Orphan => \@write_orphans);
    $self->populate(Binary => \@write_bin);
}

sub flush_reporting {
    my $self = shift;

    return;

    my @write;

    my %mixin_run = (
        user_idx    => $self->user_idx,
        run_id     => $self->{+RUN_ID},
        project_idx => $self->{+PROJECT_IDX},
    );

    my $jobs = $self->{+JOBS};
    for my $tries (values %$jobs) {
        for my $job (values %$tries) {
            my $strip_event_id = 0;

            $strip_event_id = 1 unless record_subtest_events(
                job  => $job->{result},
                fail => $job->{result}->fail,
                mode => $self->{+MODE},

                is_harness_out => 0,
            );

            my %mixin = (
                %mixin_run,
                job_try      => $job->{job_try} // 0,
                job_key      => $job->{job_key},
                test_file_idx => $job->{result}->test_file_idx,
            );

            if (my $duration = $job->{duration}) {
                my $fail  = $job->{result}->fail // 0;
                my $pass  = $fail ? 0 : 1;
                my $retry = $job->{result}->retry // 0;
                my $abort = (defined($fail) || defined($retry)) ? 0 : 1;

                push @write => {
                    duration     => $duration,
                    pass         => $pass,
                    fail         => $fail,
                    abort        => $abort,
                    retry        => $retry,
                    %mixin,
                };
            }

            my $reporting = delete $job->{reporting};

            for my $rep (@$reporting) {
                next unless defined $rep->{duration};
                next unless defined $rep->{subtest};

                delete $rep->{event_id} if $strip_event_id;

                %$rep = (
                    %mixin,
                    %$rep,
                );

                push @write => $rep;
            }
        }
    }

    return unless @write;

    local $ENV{DBIC_DT_SEARCH_OK} = 1;

    $self->populate(Reporting => \@write);
}

sub user {
    my $self = shift;

    return $self->{+RUN}->user if $self->{+RUN};
    return $self->{+USER} if $self->{+USER};

    my $user_idx = $self->{+USER_IDX} // confess "No user or user_idx specified";

    my $schema = $self->schema;
    my $user = $schema->resultset('User')->find({user_idx => $user_idx});
    return $user if $user;
    confess "Invalid user_idx: $user_idx";
}

sub user_idx {
    my $self = shift;

    return $self->{+RUN}->user_idx if $self->{+RUN};
    return $self->{+USER}->user_idx if $self->{+USER};
    return $self->{+USER_IDX} if $self->{+USER_IDX};
}

sub project {
    my $self = shift;

    return $self->{+RUN}->project if $self->{+RUN};
    return $self->{+PROJECT} if $self->{+PROJECT};

    my $project_idx = $self->{+PROJECT_IDX} // confess "No project or project_idx specified";

    my $schema = $self->schema;
    my $project = $schema->resultset('Project')->find({project_idx => $project_idx});
    return $project if $project;
    confess "Invalid project_idx: $project_idx";
}

sub project_idx {
    my $self = shift;

    return $self->{+RUN}->project_idx if $self->{+RUN};
    return $self->{+PROJECT}->project_idx if $self->{+PROJECT};
    return $self->{+PROJECT_IDX} if $self->{+PROJECT_IDX};
}

sub start {
    my $self = shift;
    return if $self->{+RUNNING};

    $self->retry_on_disconnect("update status" => sub { $self->{+RUN}->update({status => 'running'}) });

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

    $job_id = uuid_inflate($job_id);
    my $job_try = $params{job_try} // 0;

    my $job = $self->{+JOBS}->{$job_id}->{$job_try};
    return $job if $job;

    my $key = gen_uuid();

    my $test_file_idx = undef;
    if (my $queue = $params{queue}) {
        my $file = $queue->{rel_file} // $queue->{file};
        $test_file_idx = $self->get_test_file_idx($file) if $file;
        $self->{+FILE_CACHE}->{$job_id} //= $test_file_idx if $test_file_idx;
    }

    $test_file_idx //= $self->{+FILE_CACHE}->{$job_id};

    my $result;
    $self->retry_on_disconnect(
        "vivify job" => sub {
            $result = $self->schema->resultset('Job')->update_or_create({
                status         => 'pending',
                job_key        => $key,
                job_id         => $job_id,
                job_try        => $job_try,
                is_harness_out => $is_harness_out,
                run_id         => $self->{+RUN}->run_id,
                fail_count     => 0,
                pass_count     => 0,
                test_file_idx   => $test_file_idx,

                $is_harness_out ? (name => "HARNESS INTERNAL LOG") : (),
            });
        }
    );

    # In case we are resuming.
    $self->retry_on_disconnect("delete old events" => sub { $result->events->delete_all() });

    # Prevent duplicate coverage when --retry is used
    if ($job_try) {
        if ($App::Yath::Schema::LOADED =~ m/(mysql|percona|mariadb)/i) {
            my $schema = $self->schema;
            $schema->storage->connected; # Make sure we are connected
            my $dbh    = $schema->storage->dbh;

            my $query = <<"            EOT";
            DELETE coverage
              FROM coverage
              JOIN jobs USING(job_key)
             WHERE job_id = ?
            EOT

            my $sth = $dbh->prepare($query);
            $sth->execute($job_id) or die $sth->errstr;
        }
        else {
            $self->retry_on_disconnect(
                "delete old coverage" => sub {
                    $self->schema->resultset('Coverage')->search({'job.job_id' => $job_id}, {join => 'job'})->delete;
                }
            );
        }
    }

    if (my $old = $self->{+JOBS}->{$job_id}->{$job_try - 1}) {
        $self->{+UNCOVER}->{$old->{job_key}}++;
    }

    $job = {
        job_key => $key,
        job_id  => $job_id,
        job_try => $job_try,

        events    => [],
        orphans   => {},
        reporting => [],

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

    if (my $res = delete $f->{db_resources}) {
        $self->insert_resources($res);
        return unless keys %$f;
    }

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
            $e->{stamp} //= $o->{stamp};
        }
        push @{$job->{events}} => $e;
    }

    $self->flush(job => $job, is_diag => $e->{is_diag});

    return;
}

sub host {
    my $self = shift;
    return $self->{+HOST} //= $self->{+CONFIG}->schema->resultset('Host')->find_or_create({hostname => hostname()});
}

sub insert_resources {
    my $self = shift;
    my ($res) = @_;

    my $stamp    = $res->{stamp};
    my $items    = $res->{items};
    my $batch_id = $res->{batch_id};

    my $config = $self->{+CONFIG};

    my $run_id  = $self->run->run_id;
    my $host_idx = $self->host->host_idx;

    my $res_rs   = $config->schema->resultset('Resource');
    my $batch_rs = $config->schema->resultset('ResourceBatch');

    my $dt_stamp = DateTime->from_epoch(epoch => $stamp, time_zone => 'local');

    my $batch = $batch_rs->create({
        resource_batch_idx => $batch_id,
        run_id            => uuid_inflate($run_id),
        host_idx           => $host_idx,
        stamp             => $dt_stamp,
    });

    $res_rs->populate($items);
}

sub finish {
    my $self = shift;
    my (@errors) = @_;

    $self->flush_all();

    my $run = $self->run;

    my $status;
    my $dur_stat;
    my $aborted = 0;

    if (@errors) {
        my $error = join "\n" => @errors;
        $status = {status => 'broken', error => $error};
        $dur_stat = 'abort';
    }
    else {
        my $stat;
        if ($self->{+SIGNAL}) {
            $stat = 'canceled';
            $dur_stat = 'abort';
            $aborted = 1;
        }
        else {
            $stat = 'complete';
            $dur_stat = $self->{+FAILED} ? 'fail' : 'pass';
        }

        $status = {status => $stat, passed => $self->{+PASSED}, failed => $self->{+FAILED}, retried => $self->{+RETRIED}};
    }

    if ($self->{+FIRST_STAMP} && $self->{+LAST_STAMP}) {
        my $duration = $self->{+LAST_STAMP} - $self->{+FIRST_STAMP};
        $status->{duration} = format_duration($duration);

        $self->retry_on_disconnect("insert duration row" => sub {
            my $fail = $aborted ? 0 : $self->{+FAILED} ? 1 : 0;
            my $pass = ($fail || $aborted) ? 0 : 1;
            my $row  = {
                run_id      => $self->{+RUN_ID},
                user_idx    => $self->user_idx,
                project_idx => $self->project_idx,
                duration    => $duration,
                retry       => 0,
                pass        => $pass,
                fail        => $fail,
                abort       => $aborted,
            };
            $self->schema->resultset('Reporting')->create($row);
        });
    }

    $self->retry_on_disconnect("update run status" => sub { $run->update($status) });

    return $status;
}

sub _process_event {
    my $self = shift;
    my ($event, $f, %params) = @_;
    my $job = $params{job};

    my $harness = $f->{harness} // {};
    my $trace   = $f->{trace}   // {};

    my $e_id   = uuid_inflate($harness->{event_id} // $event->{event_id} // die "No event id!");
    my $nested = $f->{hubs}->[0]->{nested} || 0;

    my @binaries;
    if ($f->{binary} && @{$f->{binary}}) {
        for my $file (@{$f->{binary}}) {
            my $data = delete $file->{data};
            $file->{data}    = 'removed';

            push @binaries => {
                event_id => $e_id,
                filename => $file->{filename},
                description => $file->{details},
                data => decode_base64($data),
                is_image => $file->{is_image} // $file->{filename} =~ m/\.(a?png|gif|jpe?g|svg|bmp|ico)$/ ? 1 : 0,
            };
        }
    }

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
        event_id    => $e_id,
        nested      => $nested,
        is_subtest  => $is_subtest,
        is_diag     => $is_diag,
        is_harness  => $is_harness,
        is_time     => $is_time,
        causes_fail => $fail,
        trace_id    => $trace->{uuid},
        job_key     => $job->{job_key},
        stamp       => $self->format_stamp($harness->{stamp} || $event->{stamp} || $params{stamp}),
        binaries    => \@binaries,
        has_binary  => @binaries ? 1 : 0,
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

            $self->add_subtest_duration($job, $e, $f) unless $nested;
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

sub add_subtest_duration {
    my $self = shift;
    my ($job, $e, $f) = @_;

    return if $f->{hubs}->[0]->{nested};

    my $parent = $f->{parent}       // return;
    my $assert = $f->{assert}       // return;
    my $st     = $assert->{details} // return;
    return if is_invalid_subtest_name($st);

    my $start    = $parent->{start_stamp} // return;
    my $stop     = $parent->{stop_stamp}  // return;
    my $duration = $stop - $start         // return;

    push @{$job->{reporting}} => {
        duration => $duration,
        subtest  => $st,
        event_id => $e->{event_id},
        abort => 0,
        retry => 0,
        $assert->{pass} ? (pass => 1, fail => 0) : (fail => 1, pass => 0),
    };
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
            my $test = $job_coverage->{test} // $job->{result}->file;

            $self->_add_coverage(
                job_key => $job->{job_key},
                test    => $test,
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

    my $test_id = $self->get_test_file_idx($params{test}) or confess("Could not get test id (for '$params{test}')");

    my $source_id  = $self->_get__id(SourceFile      => 'source_file_idx',      filename => $params{source}) or die "Could not get source id";
    my $sub_id     = $self->_get__id(SourceSub       => 'source_sub_idx',       subname  => $params{sub})    or die "Could not get sub id";
    my $manager_id = $self->_get__id(CoverageManager => 'coverage_manager_idx', package  => $params{manager});

    my $meta = $manager_id ? encode_json($params{meta}) : undef;

    my $coverage = $self->{+COVERAGE} //= [];

    push @$coverage => {
        run_id              => $self->{+RUN_ID},
        test_file_idx        => $test_id,
        source_file_idx      => $source_id,
        source_sub_idx       => $sub_id,
        coverage_manager_idx => $manager_id,
        metadata            => $meta,
        job_key             => $params{job_key},
    };
}

sub flush_coverage {
    my $self = shift;

    my $coverage = $self->{+COVERAGE} or return;
    return unless @$coverage;

    $self->retry_on_disconnect("update has_coverage" => sub { $self->{+RUN}->update({has_coverage => 1}) })
        unless $self->{+RUN}->has_coverage;

    $self->populate(Coverage => $coverage);

    @$coverage = ();

    return;
}

sub _get__id {
    my $self = shift;
    my ($type, $id_field, $field, $id) = @_;
    my $out = $self->_get___id(@_);
    return $out unless defined $out;
    return $out if $id_field =~ m/_idx$/;
    return uuid_inflate($out);
}

sub _get___id {
    my $self = shift;
    my ($type, $id_field, $field, $id) = @_;

    return undef unless $id;

    return $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id}
        if $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id};

    my $spec = {$field => $id};

    # idx fields are always auto-increment, otherwise the id is uuid
    $spec->{$id_field} = gen_uuid() unless $id_field =~ m/_idx$/;

    my $result = $self->schema->resultset($type)->find_or_create($spec);

    return $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id} = $result->$id_field;
}

sub get_test_file_idx {
    my $self = shift;
    my ($file) = @_;

    return undef unless $file;

    return $self->_get__id('TestFile' => 'test_file_idx', filename => $file);
}

sub add_io_streams {
    my $self = shift;
    my ($job, @streams) = @_;

    my $job_key = $job->job_key;

    my @write;
    for my $s (@streams) {
        my ($stream, $output) = @$s;
        $output = clean_output($output);
        next unless defined $output && length($output);

        push @write => {
            job_key => $job_key,
            stream => uc($stream),
            output => $output,
        };
    }

    $self->populate('JobOutput' => \@write);
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

    $self->populate($type => \@add);
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
        $self->schema->resultset('RunParameter')->find_or_create({
            run_id => $run->run_id,
            parameters => $run_data,
        });

        if (my $fields = $run_data->{harness_run_fields} // $run_data->{fields}) {
            $self->add_run_fields($fields);
        }
    }

    my $job_result = $job->{result};
    my %cols = $job_result->get_columns;

    # Handle job events
    if (my $job_data = $f->{harness_job}) {
        #$cols{test_file_idx} ||= $self->get_test_file_idx($job_data->{file});
        $cols{name} ||= $job_data->{job_name};
        $f->{harness_job}  = "Removed, see job with job_key $cols{job_key}";

        clean($job_data);
        $self->schema->resultset('JobParameter')->find_or_create({
            job_key => uuid_deflate($job_result->job_key),
            parameters => $job_data,
        });

    }
    if (my $job_exit = $f->{harness_job_exit}) {
        #$cols{test_file_idx} ||= $self->get_test_file_idx($job_exit->{file});
        $cols{exit_code} = $job_exit->{exit};

        if ($job_exit->{retry} && $job_exit->{retry} eq 'will-retry') {
            $cols{retry} = 1;
            $self->{+RETRIED}++;
            $self->{+FAILED}--;
        }
        else {
            $cols{retry} = 0;
        }

        $self->add_io_streams(
            $job_result,
            [STDERR => delete $job_exit->{stderr}],
            [STDOUT => delete $job_exit->{stdout}],
        );
    }
    if (my $job_start = $f->{harness_job_start}) {
        $cols{test_file_idx} ||= $self->get_test_file_idx($job_start->{rel_file}) if $job_start->{rel_file};
        $cols{test_file_idx} ||= $self->get_test_file_idx($job_start->{file});
        $cols{start} = $self->format_stamp($job_start->{stamp});
    }
    if (my $job_launch = $f->{harness_job_launch}) {
        $cols{status} = 'running';

        $cols{test_file_idx} ||= $self->get_test_file_idx($job_launch->{file});
        $cols{launch} = $self->format_stamp($job_launch->{stamp});
    }
    if (my $job_end = $f->{harness_job_end}) {
        #$cols{test_file_idx} ||= $self->get_test_file_idx($job_end->{file});
        $cols{fail} ||= $job_end->{fail} ? 1 : 0;
        $cols{ended} = $self->format_stamp($job_end->{stamp});

        $cols{fail} ? $self->{+FAILED}++ : $self->{+PASSED}++;

        # All done
        $job->{done} = 1;
        $cols{status} = 'complete';

        if ($job_end->{rel_file} && $job_end->{times} && $job_end->{times}->{totals} && $job_end->{times}->{totals}->{total}) {
            my $tfile_id = $cols{test_file_idx} ||= $self->get_test_file_idx($job_end->{rel_file}) if $job_end->{rel_file};

            if (my $duration = $job_end->{times}->{totals}->{total}) {
                $job->{duration} = $duration;
                $cols{duration} = $duration;
            }
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

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::RunProcessor

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
