package Test2::Harness::UI::Controller::Project;
use strict;
use warnings;

our $VERSION = '0.000112';

use Time::Elapsed qw/elapsed/;
use List::Util qw/sum/;
use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir format_duration parse_duration/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

my %BAD_ST_NAME = (
    '__ANON__'            => 1,
    'unnamed'             => 1,
    'unnamed subtest'     => 1,
    'unnamed summary'     => 1,
    '<UNNAMED ASSERTION>' => 1,
);

sub title { 'Project Stats' }

sub users {
    my $self = shift;
    my ($project) = @_;

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my $query = <<"    EOT";
        SELECT users.user_id AS user_id, users.username AS username
          FROM users
          JOIN runs USING(user_id)
         WHERE runs.project_id = ?
         GROUP BY user_id
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id) or die $sth->errstr;

    my $owner = $project->owner;
    my @out;
    for my $row (@{$sth->fetchall_arrayref // []}) {
        my ($user_id, $username) = @$row;
        my $is_owner = ($owner && $user_id eq $owner->user_id) ? 1 : 0;
        push @out => {user_id => $user_id, username => $username, owner => $is_owner};
    }

    @out = sort { $b->{owner} cmp $a->{owner} || $a->{username} cmp $b->{username} } @out;

    return \@out;
}


sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->request;
    my $it = $route->{id} or die error(404 => 'No id');

    my $n     = $route->{n}     // 25;
    my $stats = $route->{stats} // 0;

    my $schema = $self->{+CONFIG}->schema;

    my $project;
    $project = $schema->resultset('Project')->single({name => $it});
    $project //= $schema->resultset('Project')->single({project_id => $it});
    error(404 => 'Invalid Project') unless $project;

    return $self->html($req, $project, $n)
        unless $stats;

    return $self->stats($req, $project);
}

sub html {
    my $self = shift;
    my ($req, $project, $n) = @_;

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $res = resp(200);
    $res->add_css('project.css');
    $res->add_js('project.js');
    $res->add_js('chart.min.js');

    my $content = $tx->render(
        'project.tx',
        {
            project  => $project,
            base_uri => $req->base->as_string,
            n        => $n,
            users    => $self->users($project),
        }
    );

    $res->raw_body($content);
    return $res;
}

sub stats {
    my $self = shift;
    my ($req, $project, $n) = @_;

    my $json = $req->content;
    my $stats = decode_json($json);

    my $res = resp(200);

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        cache => 0,

        done => sub {
            return 0 if @$stats;
            return 1;
        },

        fetch => sub {
            my $data = $self->build_stat($project => shift(@$stats));
            return encode_json($data) . "\n";
        },
    );

    return $res;
}

my %VALID_TYPES = (
    coverage           => 1,
    uncovered          => 1,
    file_failures      => 1,
    sub_failures       => 1,
    file_durations     => 1,
    sub_durations      => 1,
    user_summary       => 1,
    expensive_users    => 1,
    expensive_files    => 1,
    expensive_subtests => 1,
);

sub build_stat {
    my $self = shift;
    my ($project, $stat) = @_;

    return unless $stat;

    my $type = $stat->{type};

    return {%$stat, error => "Invalid type '$type'"} unless $VALID_TYPES{$type};

    $stat->{users} //= [];

    eval {
        my $meth = "_build_stat_$type";
        $self->$meth($project => $stat);
        1;
    } or return {%$stat, error => $@};

    return $stat;
}

sub _build_stat_expensive_files {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};
    my $users = $stat->{users};

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my $user_query = @$users ? 'AND runs.user_id in (' . join(',' => map { '?' } @$users ) . ')' : '';

    my $query = <<"    EOT";
        SELECT users.username,
               test_files.filename,
               jobs.run_id, jobs.duration, jobs.fail, jobs.retry
          FROM jobs
          JOIN runs       USING(run_id)
          JOIN test_files USING(test_file_id)
          JOIN users      USING(user_id)
         WHERE runs.project_id = ?
           AND runs.status IN ('complete', 'canceled')
           AND jobs.duration IS NOT NULL
           $user_query
      ORDER BY runs.added, runs.run_ord
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @$users) or die $sth->errstr;

    my %runs;
    my %data;
    while (my $row = $sth->fetchrow_hashref) {
        my ($user, $file, $run_id, $duration, $fail, $retry) = @$row{qw/username filename run_id duration fail retry/};
        next unless $duration;

        if ($n) {
            $runs{$run_id} //= 1;
            last if scalar(keys %runs) > $n;
        }

        my $fdata = $data{$file} //= {file => $file, users => {}, runs => {}, duration => 0, fail => 0, retry => 0, pass => 0};
        $fdata->{users}->{$user}++;
        $fdata->{runs}->{$run_id}++;
        $fdata->{duration} += $duration;
        $fdata->{retry}++ if $retry;
        $fdata->{$fail ? 'fail' : 'pass'}++;
    }

    my @rows;
    for my $row (sort {$b->{duration} <=> $a->{duration}} values %data) {
        $row->{runs}    = keys(%{$row->{runs}})  || 1;
        $row->{users}   = keys(%{$row->{users}}) || 1;
        $row->{average} = ($row->{duration} / $row->{runs});

        push @rows => [
            {},
            @$row{qw/file/},
            {formatted => format_duration($row->{duration}), raw => $row->{duration}},
            {formatted => format_duration($row->{average}), raw => $row->{average}},
            @$row{qw/runs users pass fail retry/},
        ];
    }

    $stat->{table} = {
        class => 'expense',
        sortable => 1,
        header => ['Test File', 'Total Time', 'Average Job Time', 'Total Jobs', 'Users Effected', 'Passes', 'Fails', 'Retries'],
        rows => \@rows,
    };
}

sub _build_stat_expensive_subtests {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};
    my $users = $stat->{users};

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my $user_query = @$users ? 'AND runs.user_id in (' . join(',' => map { '?' } @$users ) . ')' : '';


    my $query = <<"    EOT";
        SELECT users.username,
               test_files.filename,
               jobs.run_id,
               events.facets
          FROM events
          JOIN jobs       USING(job_key)
          JOIN runs       USING(run_id)
          JOIN test_files USING(test_file_id)
          JOIN users      USING(user_id)
         WHERE events.is_subtest = TRUE
           AND events.nested = 0
           AND events.facets IS NOT NULL
           AND runs.project_id = ?
           AND runs.status in ('complete', 'canceled')
           $user_query
      ORDER BY runs.added, runs.run_ord
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @$users) or die $sth->errstr;

    my %runs;
    my %data;
    while (my $row = $sth->fetchrow_hashref) {
        my ($user, $file, $run_id, $facets) = @$row{qw/username filename run_id facets/};
        if ($n) {
            $runs{$run_id} //= 1;
            last if scalar(keys %runs) > $n;
        }

        $facets = decode_json($facets) unless ref $facets;
        my $assert = $facets->{assert} // next;
        my $parent = $facets->{parent} // next;
        my $st = $assert->{details} || next;
        next if $BAD_ST_NAME{$st};

        my $start = $parent->{start_stamp} // next;
        my $stop  = $parent->{stop_stamp}  // next;
        my $duration = $stop - $start;

        my $fdata = $data{$file}->{$st} //= {file => $file, subtest => $st, duration => 0, average => 0, users => {}, runs => {}, pass => 0, fail => 0};
        $fdata->{users}->{$user}++;
        $fdata->{runs}->{$run_id}++;
        $fdata->{duration} += $duration;
        $fdata->{$assert->{pass}? 'pass' : 'fail'}++;
    }

    my @rows;
    for my $row (sort {$b->{duration} <=> $a->{duration}} map { values %{$_} } values %data) {
        $row->{runs}    = keys(%{$row->{runs}})  || 1;
        $row->{users}   = keys(%{$row->{users}}) || 1;
        $row->{average} = ($row->{duration} / $row->{runs});

        push @rows => [
            {},
            @$row{qw/file subtest/},
            {formatted => format_duration($row->{duration}), raw => $row->{duration}},
            {formatted => format_duration($row->{average}), raw => $row->{average}},
            @$row{qw/runs users pass fail/},
        ];
    }

    $stat->{table} = {
        class => 'expense',
        sortable => 1,
        header => ['Test File', 'Subtest', 'Total Time', 'Average Subtest Time', 'Times Executed', 'Users Effected', 'Passes', 'Fails'],
        rows => \@rows,
    };

    #FILENAME/USER | [SUBTEST] |  TOTAL TIME | TOTAL RUNS | [USER COUNT] | AVERAGE RUN TIME | PASSES | FAILS | RETRIES
}

sub _build_stat_expensive_users {
    my $self = shift;
    my ($project, $stat) = @_;

    my $fetch = $self->_get_n_runs_expense_data($project, $stat);

    my %data;
    while (my $row = $fetch->()) {
        my ($status, $duration, $passed, $failed, $retried, $username) = @$row{qw/status duration passed failed retried username/};
        my $udata = $data{$username} //= {user => $username, total_time => 0, total_runs => 0, passes => 0, fails => 0, cancels => 0};

        $udata->{total_runs}++;

        $duration = parse_duration($duration);
        $udata->{total_time} += $duration;

        if ($status ne 'complete') {
            $udata->{cancels}++;
        }
        elsif ($failed) {
            $udata->{fails}++;
        }
        else {
            $udata->{passes}++;
        }
    }

    my @rows;
    for my $row (sort { $b->{total_time} <=> $a->{total_time} } values %data) {
        $row->{average_time} = $row->{total_time} / $row->{total_runs};
        $row->{total_time} = $row->{total_time};

        push @rows => [
            {},
            $row->{user},
            {formatted => format_duration($row->{total_time}), raw => $row->{total_time}},
            $row->{total_runs},
            {formatted => format_duration($row->{average_time}), raw => $row->{average_time}},
            $row->{passes},
            $row->{fails},
            $row->{cancels},
        ];
    }

    $stat->{table} = {
        class => 'expense',
        sortable => 1,
        header => ['User', 'Total Time', 'Total Runs', 'Average Run Time', 'Passed', 'Fails', 'Cancels'],
        rows => \@rows,
    };
}

sub _get_n_runs_expense_data {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};
    my $users = $stat->{users};

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my $user_query = @$users ? 'AND run.user_id in (' . join(',' => map { '?' } @$users ) . ')' : '';
    my $limit_query = $n ? 'LIMIT ?' : '';

    my $query = <<"    EOT";
        SELECT run.status, run.duration, run.passed, run.failed, run.retried, users.username
          FROM runs AS run
          JOIN users USING(user_id)
         WHERE run.project_id = ?
           AND run.status IN ('complete', 'canceled')
           AND run.duration IS NOT NULL
           $user_query
      ORDER BY run.added, run.run_ord
           $limit_query
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @$users, $n ? ($n) : ()) or die $sth->errstr;

    return sub { $sth->fetchrow_hashref };
}

sub _build_stat_user_summary {
    my $self = shift;
    my ($project, $stat) = @_;

    my $fetch = $self->_get_n_runs_expense_data($project, $stat);

    my $data = {};
    while (my $row = $fetch->()) {
        my ($status, $duration, $passed, $failed, $retried, $username) = @$row{qw/status duration passed failed retried username/};
        next unless $duration;

        $data->{runs}++;
        unless ($data->{users}->{$username}++) {
            $data->{unique_users}++;
        }

        $duration = parse_duration($duration);
        $data->{total_durations} += $duration;
        push @{$data->{durations}} => $duration;

        $data->{passed_files}  += $passed  if $passed;
        $data->{failed_files}  += $failed  if $failed;
        $data->{retried_files} += $retried if $retried;

        if ($status ne 'complete') {
            $data->{incomplete_runs}++;
        }
        elsif ($failed) {
            $data->{failed_runs}++;
        }
        else {
            $data->{passed_runs}++;
        }
    }

    $data->{runs} //= 1;            # Avoid divide by 0
    $data->{unique_users} ||= 1;    # Avoid divide by 0
    $data->{total_durations} //= 0;

    $data->{run_average_time}  = $data->{total_durations} / $data->{unique_users};
    $data->{user_average_time} = $data->{total_durations} / $data->{runs};
    $data->{file_average_time} = $data->{total_durations} / (sum($data->{passed_files} //= 0, $data->{failed_files} //= 0, $data->{retried_files} //= 0) || 1);
    $data->{user_average_runs} = $data->{runs} / $data->{unique_users};

    $stat->{pairs} = [
        ["Total time spent running tests" => format_duration($data->{total_durations}    // 0)],
        ["Average time per test run"      => format_duration($data->{run_average_time}   // 0)],
        ["Average time per user"          => format_duration($data->{user_average_time}  // 0)],
        ["Average time per file"          => format_duration($data->{file_average_time}  // 0)],
        ["Average runs per user"          => sprintf("%0.2f", $data->{user_average_runs} // 0)],
        ["Total unique users"             => scalar(keys %{$data->{users} // {}}) // 0],
        ["Total runs"                     => $data->{runs}                        // 0],
        ["Total incomplete runs"          => $data->{incomplete_runs}             // 0],
        ["Total passed runs"              => $data->{passed_runs}                 // 0],
        ["Total failed runs"              => $data->{failed_runs}                 // 0],
        ["Total passed files"             => $data->{passed_files}                // 0],
        ["Total failed files"             => $data->{failed_files}                // 0],
        ["Total retried files"            => $data->{retried_files}               // 0],
    ];
}

sub _build_stat_file_durations {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};
    my $users = $stat->{users};

    my $schema = $self->{+CONFIG}->schema;

    my $fields_rs = $schema->resultset('JobField')->search(
        {
            'me.name'        => 'time_total',
            'run.status'     => 'complete',
            'run.project_id' => $project->project_id,
            @$users ? (user_id => {'-in' => $users}) : ()
        },
        {
            join     => {job_key => 'run'},
            order_by => {'-DESC' => 'run.added'},
            prefetch => 'job_key'
        },
    );

    my %runs;
    my %files;
    while (my $field = $fields_rs->next) {
        $runs{$field->job_key->run_id} = 1;
        last if $n && keys %runs > $n;

        my $file = $field->job_key->file or next;
        my $val = $field->raw or next;
        push @{$files{$file}} => $val;
    }

    for my $file (keys %files) {
        if (!$files{$file} || !@{$files{$file}}) {
            delete $files{$file};
            next;
        }

        $files{$file} = sum(@{$files{$file}}) / @{$files{$file}};
    }

    my @sorted = sort { $files{$b} <=> $files{$a} } keys %files;

    return $stat->{text} = "No Duration Data"
        unless @sorted;

    $stat->{table} = {
        header => ['Duration', 'Test', 'Raw Duration'],
        rows => [
            map {
                my $dur = $files{$_};
                my $disp = elapsed($dur);
                if (!$disp || $disp =~ m/^\d seconds?$/) {
                    $disp = sprintf('%1.1f seconds', $dur);
                }
                [{}, $disp, $_, $dur]
            } grep { $_ } @sorted,
        ],
    };
}

sub _build_stat_sub_durations {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};

    my $schema = $self->{+CONFIG}->schema;

    my $users     = $stat->{users};
    my $events_rs = $schema->resultset('Event')->search(
        {
            'me.is_subtest'  => 1,
            'run.status'     => 'complete',
            'run.project_id' => $project->project_id,
            @$users ? (user_id => {'-in' => $users}) : ()
        },
        {
            join     => {job_key => 'run'},
            order_by => {'-DESC' => 'run.added'},
            prefetch => 'job_key'
        },
    );

    my %runs;
    my %files;
    while (my $event = $events_rs->next) {
        $runs{$event->job_key->run_id} = 1;
        last if $n && keys %runs > $n;

        next if $event->nested;
        my $file = $event->job_key->file or next;

        my $facets = $event->facets or next;
        my $assert = $facets->{assert} // next;
        my $parent = $facets->{parent} // next;
        my $name = $assert->{details} || next;
        next if $BAD_ST_NAME{$name};

        my $start = $parent->{start_stamp} // next;
        my $stop  = $parent->{stop_stamp}  // next;

        push @{$files{$file}->{$name}} => ($stop - $start);
    }

    my @stats;
    for my $file (keys %files) {
        my $subs = $files{$file} or next;

        for my $sub (keys %$subs) {
            my $items = $subs->{$sub} or next;
            next unless @$items;

            push @stats => {
                file => $file,
                sub => $sub,
                duration => (sum(@$items) / @$items),
            }
        }
    }

    my @sorted = sort { $b->{duration} <=> $a->{duration} } @stats;

    return $stat->{text} = "No Duration Data"
        unless @sorted;

    $stat->{table} = {
        header => ['Duration', 'Subtest', 'File', 'Raw Duration'],
        rows => [
            map {
                my $dur = $_->{duration};
                my $disp = elapsed($dur);
                if (!$disp || $disp =~ m/^(\d|zero) seconds?$/) {
                    $disp = sprintf('%1.1f seconds', $dur);
                }
                [{}, $disp, $_->{sub}, $_->{file}, $dur]
            } @sorted,
        ],
    };
}


sub _build_stat_sub_failures {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};

    my $schema = $self->{+CONFIG}->schema;

    my $users     = $stat->{users};
    my $events_rs = $schema->resultset('Event')->search(
        {
            'me.is_subtest'  => 1,
            'run.status'     => 'complete',
            'run.project_id' => $project->project_id,
            @$users ? (user_id => {'-in' => $users}) : ()
        },
        {
            join     => {job_key => 'run'},
            order_by => {'-DESC' => 'run.added'},
            prefetch => 'job_key'
        },
    );

    my %runs;
    my %files;
    my $rc = 0;
    while (my $event = $events_rs->next) {
        $runs{$event->job_key->run_id} = 1;
        last if $n && keys %runs > $n;
        $rc = scalar keys %runs;

        next if $event->nested;
        my $file = $event->job_key->file or next;

        my $facets = $event->facets or next;
        my $assert = $facets->{assert} // next;
        my $name = $assert->{details} || next;
        next if $BAD_ST_NAME{$name};

        $files{$file}->{$name}->{total}++;
        next if $assert->{pass};

        $files{$file}->{$name}->{fails}++;
        $files{$file}->{$name}->{last_fail} ||= $rc;
    }

    my @stats;
    for my $file (keys %files) {
        my $subs = $files{$file};

        for my $sub (keys %$subs) {
            my $set = $subs->{$sub};
            my $fails = $set->{fails};
            my $total = $set->{total};
            my $last_fail = $set->{last_fail};

            next unless $fails && $total;

            my $p = $set->{percent} = int($fails / $total * 100);
            push @stats => {
                file => $file,
                sub  => $sub,
                total => $total,
                fails => $fails,
                percent => $p,
                rate => "$fails/$total ($p\%)",
                last_fail => $last_fail,
            };
        }
    }

    my @sorted = sort { $b->{percent} <=> $a->{percent} } @stats;

    return $stat->{text} = "No Failures in given run range!"
        unless @sorted;

    $stat->{table} = {
        header => ['Failure Rate', 'Subtest', 'File', 'Runs Since Last Failure'],
        rows   => [map { [{}, $_->{rate}, $_->{sub}, $_->{file}, $_->{last_fail}] } @sorted],
    };
}

sub _build_stat_file_failures {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};

    my $schema = $self->{+CONFIG}->schema;

    my $users   = $stat->{users};
    my $jobs_rs = $schema->resultset('Job')->search(
        {
            'run.status'     => 'complete',
            'run.project_id' => $project->project_id,
            @$users ? (user_id => {'-in' => $users}) : ()
        },
        {
            join     => 'run',
            order_by => {'-DESC' => 'run.added'}
        },
    );

    my %runs;
    my %files;
    my $rc = 0;
    while (my $job = $jobs_rs->next) {
        $runs{$job->run_id} = 1;
        last if $n && keys %runs > $n;
        $rc = scalar keys %runs;

        $rc++;
        my $file = $job->file or next;

        $files{$file}->{total}++;

        next unless $job->fail;
        $files{$file}->{fails}++;
        $files{$file}->{last_fail} ||= $rc;
    }

    for my $file (keys %files) {
        my $set = $files{$file};
        my $fails = $set->{fails};
        my $total = $set->{total};

        if (!$fails) {
            delete $files{$file};
            next;
        }

        my $p = $set->{percent} = int($fails / $total * 100);
        $set->{rate} = "$fails/$total ($p\%)";
    }

    my @sorted = sort { $files{$b}->{percent} <=> $files{$a}->{percent} } keys %files;

    return $stat->{text} = "No Failures in given run range!"
        unless @sorted;

    $stat->{table} = {
        header => ['Failure Rate', 'Test', 'Runs Since Last Failure'],
        rows => [
            map {
                my $set = $files{$_};
                [{}, $set->{rate}, $_, $set->{last_fail}]
            } grep { $_ } @sorted,
        ],
    };
}

sub _build_stat_uncovered {
    my $self = shift;
    my ($project, $stat) = @_;

    my $schema = $self->{+CONFIG}->schema;

    my $users = $stat->{users};
    my $field = $schema->resultset('RunField')->search(
        {
            'me.name'        => 'coverage',
            'me.data'        => \'IS NOT NULL',
            'run.project_id' => $project->project_id,
            'run.has_coverage' => 1,
            @$users ? (user_id => {'-in' => $users}) : ()
        },
        {
            join     => 'run',
            order_by => {'-DESC' => 'run.added'},
            rows     => 1
        },
    )->first;

    return $stat->{text} = "No coverage data."
        unless $field;

    my $untested = $field->data->{untested};
    my $files = $untested->{files} // [];
    my $subs  = $untested->{subs}  // {};

    my $data = {};
    for my $file (sort @$files, keys %$subs) {
        $data->{$file} //= $subs->{$file} // [];
    }

    return $stat->{text} = "Full Coverage!"
        unless keys %$data;

    $stat->{json} = $data;
}

sub _build_stat_coverage {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};

    my $schema = $self->{+CONFIG}->schema;

    my $users = $stat->{users};
    my @items = reverse $schema->resultset('RunField')->search(
        {
            'me.name'        => 'coverage',
            'me.data'        => \'IS NOT NULL',
            'run.project_id' => $project->project_id,
            'run.has_coverage' => 1,
            @$users ? (user_id => {'-in' => $users}) : ()
        },
        {
            join     => 'run',
            order_by => {'-DESC' => 'run.added'},
            $n ? (rows => $n) : (),
        },
    )->all;

    my $labels = [];
    my $subs   = [];
    my $files  = [];
    for my $item (@items) {
        next unless $item->data;
        push @$labels => '';
        my $metrics = $item->data->{metrics} // $item->data;
        push @$files => int($metrics->{files}->{tested} / $metrics->{files}->{total} * 100) if $metrics->{files}->{total};
        push @$subs  => int($metrics->{subs}->{tested} / $metrics->{subs}->{total} * 100) if $metrics->{subs}->{total};
    }

    return $stat->{text} = "No sub or file data."
        unless @$files || @$subs;

    $stat->{chart} = {
        type => 'line',
        data => {
            labels => $labels,
            datasets => [
                {
                    label => 'Subroutine Coverage',
                    data => $subs,
                    borderColor => 'rgb(50, 255, 50)',
                    backgroundColor => 'rgb(50, 255, 50)',
                },
                {
                    label => 'File Coverage',
                    data => $files,
                    borderColor => 'rgb(50, 50, 255)',
                    backgroundColor => 'rgb(50, 50, 255)',
                }
            ],
        },
        options => {
            elements => {
                point => { radius => 3 },
                line =>  { borderWidth => 1 },
            },
            scales => {
                y => {
                    beginAtZero => \1,
                    ticks => {
                        callback => 'percent',
                    },
                },
            },
        },
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Project

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
