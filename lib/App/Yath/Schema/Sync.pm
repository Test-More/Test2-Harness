package App::Yath::Schema::Sync;
use strict;
use warnings;

use DBI;
use DateTime;
use Scope::Guard;
use Carp qw/croak/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Util::UUID qw/gen_uuid/;

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase;

sub run_delta {
    my $self = shift;
    my ($dbh_a, $dbh_b) = @_;

    my $refa = ref($dbh_a);
    my $refb = ref($dbh_b);

    my $a_runs = $refa eq 'HASH' ? $dbh_a : $self->get_runs($dbh_a);
    my $b_runs = $refb eq 'HASH' ? $dbh_b : $self->get_runs($dbh_b);

    for my $run_uuid (keys %$a_runs, keys %$b_runs) {
        # If both have it, delete from both
        next unless $a_runs->{$run_uuid} && $b_runs->{$run_uuid};
        delete $a_runs->{$run_uuid};
        delete $b_runs->{$run_uuid};
    }

    return {
        missing_in_a => $b_runs,
        missing_in_b => $a_runs,
    };
}

sub sync {
    my $self = shift;
    my %params = @_;

    my $from_dbh  = $params{from_dbh}  or croak "Need a DBH to pull data (from_dbh)";
    my $to_dbh    = $params{to_dbh}    or croak "Need a DBH to push data TO (to_dbh)";
    my $run_uuids = $params{run_uuids} or croak "Need a list of run_uuid's to sync";

    my $name  = $params{name}  // "$from_dbh -> $to_dbh";
    my $skip  = $params{skip}  // {};
    my $cache = $params{cache} // {};
    my $debug = $params{debug} // 0;

    

    my ($rh, $wh);
    pipe($rh, $wh) or die "Could not open pipe: $!";
    $wh->autoflush(1);

    my $pid = fork // die "Could not fork: $!";
    unless ($pid) {
        close($wh);

        my $guard = Scope::Guard->new(sub {
            warn "Scope Leak";
            exit 255;
        });

        $self->read_sync(
            dbh       => $to_dbh,
            run_uuids => $run_uuids,
            rh        => $rh,
            cache     => $cache,
            debug     => $debug,
        );

        $guard->dismiss();

        exit 0;
    }

    close($rh);
    $self->write_sync(
        dbh       => $from_dbh,
        run_uuids => $run_uuids,
        wh        => $wh,
        skip      => $skip,
        debug     => $debug,
    );
    close($wh);

    die "Loader exited badly" if $self->wait_on($pid => "[Loader] $name");

    return;
}

sub wait_on {
    my $self = shift;
    my ($pid, $desc) = @_;

    my $out = 0;

    my $check = waitpid($pid, 0);
    my $exit = $?;
    if ($check != $pid) {
        warn "$desc waitpid failed: $check (exit: $?)";
        return $exit || 1;
    }

    return 0 unless $exit;
    warn "$desc exited badly: $exit\n";
    return $exit;
}

sub get_runs {
    my $self = shift;
    my ($dbh_or_file) = @_;

    return $self->_get_dbh_runs($dbh_or_file);
}

sub _get_dbh_runs {
    my $self = shift;
    my ($dbh) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT run_uuid, run_id
        FROM   runs
        WHERE  status NOT IN ('pending', 'running', 'broken')
        ORDER  BY added ASC
    EOT

    $sth->execute() or die "Error: " . $dbh->errstr;

    my %out;

    while (my $run = $sth->fetchrow_arrayref()) {
        $out{$run->[0]} = $run->[1];
    }

    return \%out;
}

sub table_list { qw/runs jobs job_tries events run_fields job_try_fields binaries reporting coverage/ }

sub write_sync {
    my $self = shift;
    my %params = @_;

    my $dbh       = $params{dbh}       or croak "'dbh' is required";
    my $run_uuids = $params{run_uuids} or croak "'run_uuids' must be a hashref of {run_uuid => run_id}";
    my $wh        = $params{wh}        or croak "'wh' is required and must be a writable filehandle";
    my $skip      = $params{skip}  // {};
    my $debug     = $params{debug} // 0;

    my @to_dump;
    for my $table ($self->table_list) {
        next if $skip->{$table};
        push @to_dump => "render_${table}";
    }

    $wh->autoflush(1);

    STDOUT->autoflush(1);

    my $total = keys %$run_uuids;
    my $counter = 0;
    my $subcount = 0;
    for my $run_uuid (keys %$run_uuids) {
        my @args = ($dbh, $run_uuid, $run_uuids->{$run_uuid}, $skip);

        for my $meth (@to_dump) {
            for my $item ($self->$meth(@args)) {
                $subcount++;
                my ($key) = keys(%$item);
                my $line = encode_json($item);
                print $wh $line, "\n";
            }
        }

        $counter++;
        if ($debug) {
            print "  Dumped run $counter/$total: $run_uuid\n";
        }
    }

    return;
}

sub read_sync {
    my $self = shift;
    my %params = @_;

    my $dbh       = $params{dbh}       or croak "'dbh' is required";
    my $run_uuids = $params{run_uuids} or croak "'run_uuids' must be a hashref of {run_uuid => run_id}";
    my $rh        = $params{rh}        or croak "'rh' is required and must be a readable filehandle";
    my $cache     = $params{cache} // {};
    my $debug     = $params{debug} // 0;

    $dbh->{AutoCommit} = 0;

    my $total = keys %$run_uuids;
    my $counter = 0;
    my $last_run_uuid;
    my $broken;
    while (my $line = <$rh>) {
        my $data = decode_json($line);

        my ($type, @bad) = keys %$data;
        die "Invalid data!" if @bad;

        $self->format_date_time($dbh, $data->{$type});

        if ($type eq 'run') {
            $dbh->commit();
            $dbh->{AutoCommit} = 0;

            if ($debug && $last_run_uuid) {
                if ($broken) {
                    print "  BROKEN run $counter/$total: $last_run_uuid\n";
                }
                else {
                    print "Imported run $counter/$total: $last_run_uuid\n";
                }
            }

            $broken = undef;
            my $new_run_uuid = $data->{$type}->{run_uuid};

            if ($new_run_uuid && !$run_uuids->{$new_run_uuid}) {
                $last_run_uuid = undef;
                next;
            }

            $last_run_uuid = $new_run_uuid;
            $counter++;
        }

        next if $broken;
        next unless $last_run_uuid;

        my $method = "import_$type";

        next if eval {
            $self->$method(dbh => $dbh, item => $data->{$type}, cache => $cache);
            1;
        };

        $dbh->rollback();
        $broken = $last_run_uuid;
    }

    $dbh->commit();
    $dbh->disconnect();

    return;
}

sub parse_date_time {
    my $self = shift;
    my ($dbh, $item) = @_;

    my $cb;
    my $driver = $dbh->{Driver}->{Name};
    if ($driver =~ m/^Pg$/i || $driver =~ m/postgresql/i) {
        require DateTime::Format::Pg;
        $cb = sub { DateTime::Format::Pg->parse_timestamptz(@_) };
    }
    elsif ($driver =~ m/(mysql|percona|mariadb)/i) {
        require DateTime::Format::MySQL;
        $cb = sub { DateTime::Format::MySQL->parse_datetime(@_) };
    }
    elsif ($driver =~ m/sqlite/) {
        require DateTime::Format::SQLite;
        $cb = sub { DateTime::Format::SQLite->parse_datetime(@_) };
    }
    else {
        die "No date parser for driver '$driver'";
    }

    for my $field (qw/accessed added created ended launch stamp start updated/) {
        next unless exists $item->{$field};
        my $val = $item->{$field} or next;
        $item->{$field} = $cb->($val)->hires_epoch;
    }
}

sub format_date_time {
    my $self = shift;
    my ($dbh, $item) = @_;

    my $cb;
    my $driver = $dbh->{Driver}->{Name};
    if ($driver =~ m/^Pg$/i || $driver =~ m/postgresql/i) {
        require DateTime::Format::Pg;
        $cb = sub { DateTime::Format::Pg->format_timestamptz(@_) };
    }
    elsif ($driver =~ m/(mysql|percona|mariadb)/i) {
        require DateTime::Format::MySQL;
        $cb = sub { DateTime::Format::MySQL->format_datetime(@_) };
    }
    elsif ($driver =~ m/sqlite/) {
        require DateTime::Format::SQLite;
        $cb = sub { DateTime::Format::SQLite->format_datetime(@_) };
    }
    else {
        die "No date parser for driver '$driver'";
    }

    for my $field (qw/accessed added created ended launch stamp start updated/) {
        next unless exists $item->{$field};
        my $val = $item->{$field} or next;
        $item->{$field} = $cb->(DateTime->from_epoch($val));
    }
}

sub get_or_create_id {
    my $self = shift;
    my ($cache, $dbh, $table, $field, $via_field, $via_value) = @_;

    return undef unless $via_value;

    return $cache->{$table}{$via_field}{$via_value}{$field} //= $self->_get_or_create_id(@_);
}

sub _get_or_create_id {
    my $self = shift;
    my ($cache, $dbh, $table, $field, $via_field, $via_value) = @_;

    my $id = $self->_get_id(@_);
    return $id if $id;

    $self->insert($dbh, $table, {$via_field => $via_value});

    return $self->_get_id(@_);
}

sub _get_id {
    my $self = shift;
    my ($cache, $dbh, $table, $field, $via_field, $via_value) = @_;

    my $sql = "SELECT $field FROM $table WHERE $via_field = ?";

    my $sth = $dbh->prepare($sql);
    $sth->execute($via_value) or die "Error: " . $dbh->errstr;
    if ($sth->rows) {
        my $row = $sth->fetchrow_hashref();
        return $row->{$field};
    }

    return;
}

sub insert {
    my $self = shift;
    my ($dbh, $table, $data) = @_;

    my $sql  = "INSERT INTO $table(";
    my (@fields, @vars);
    for my $key (keys %$data) {
        push @fields => $key;
        push @vars => $data->{$key};
    }
    $sql .= join(',', @fields) . ') VALUES(' . join(',', map { '?' } @vars) . ')';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@vars) or die "Insert failed: " . $dbh->errstr;
}

sub render_runs {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id, $skip) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            passed, failed, to_retry, retried, concurrency_j,
            concurrency_x, added, status, mode, pinned, has_coverage,
            has_resources, parameters, worker_id, error, duration,
            users.username, projects.name as project_name
        FROM runs
        JOIN users    USING(user_id)
        JOIN projects USING(project_id)
        WHERE run_id = ?
    EOT

    $sth->execute($run_id) or die "Error: " . $dbh->errstr;

    my $run = $sth->fetchrow_hashref();
    $run->{run_uuid} = $run_uuid;
    $run->{canon} = 0;
    delete $run->{has_coverage}  if $skip->{coverage};
    delete $run->{has_resources} if $skip->{resources};

    $self->parse_date_time($dbh, $run);

    return {run => $run};
}

sub render_run_fields {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT event_uuid, name, data, details, raw, link
          FROM run_fields
         WHERE run_id = ?
    EOT
    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $run_fields = $sth->fetchall_arrayref({});

    return map { $_->{run_uuid} = $run_uuid; $self->parse_date_time($dbh, $_); +{run_field => $_} } @$run_fields;
}

sub render_jobs {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            job_uuid, is_harness_out, failed, passed,
            test_files.filename
          FROM jobs
          JOIN test_files USING (test_file_id)
         WHERE run_id = ?
    EOT

    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $jobs = $sth->fetchall_arrayref({});
    return map { $_->{run_uuid} = $run_uuid; $self->parse_date_time($dbh, $_); +{job => $_} } @$jobs;
}

sub render_job_tries {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            job_try_uuid, pass_count, fail_count, exit_code, launch, start,
            ended, status, job_try_ord, fail, retry, duration, parameters,
            stdout, stderr,
            jobs.job_uuid
          FROM job_tries
          JOIN jobs USING(job_id)
         WHERE jobs.run_id = ?
    EOT

    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $jobs = $sth->fetchall_arrayref({});
    return map {$self->parse_date_time($dbh, $_); +{job_try => $_} } @$jobs;
}

sub render_job_try_fields {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            event_uuid, name, data, details, raw, link,
            job_tries.job_try_uuid
          FROM job_try_fields
          JOIN job_tries USING(job_try_id)
          JOIN jobs      USING(job_id)
         WHERE jobs.run_id = ?
    EOT

    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $job_fields = $sth->fetchall_arrayref({});
    return map {$self->parse_date_time($dbh, $_); +{job_try_field => $_} } @$job_fields;
}

sub render_events {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT events.*, job_try_uuid
          FROM events
          JOIN job_tries USING(job_try_id)
          JOIN jobs      USING(job_id)
         WHERE jobs.run_id = ?
           AND is_subtest = TRUE
      ORDER BY event_id
    EOT

    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $events = $sth->fetchall_arrayref({});
    return map {$self->parse_date_time($dbh, $_); +{event => $_} } @$events;
}

sub render_binaries {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            B.event_uuid, B.is_image, B.filename, B.description, B.data
          FROM binaries  AS B
          JOIN events    USING(event_id)
          JOIN job_tries USING(job_try_id)
          JOIN jobs      USING(job_id)
         WHERE run_id = ?
           AND is_subtest = TRUE
    EOT

    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $binaries = ($sth->fetchall_arrayref({}));
    return map {$self->parse_date_time($dbh, $_); +{binary => $_} } @$binaries;
}

sub render_reporting {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            R.job_try, R.retry, R.abort, R.fail, R.pass, R.subtest, R.duration,
            job_tries.job_try_uuid  AS job_try_uuid,
            projects.name           AS project_name,
            users.username          AS username,
            test_files.filename     AS filename
          FROM reporting  AS R
          JOIN job_tries  USING(job_try_id)
          JOIN projects   USING(project_id)
          JOIN users      USING(user_id)
          JOIN test_files USING(test_file_id)
         WHERE run_id = ?
    EOT
    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $reporting = $sth->fetchall_arrayref({});
    return map { $_->{run_uuid} = $run_uuid; $self->parse_date_time($dbh, $_); +{reporting => $_} } @$reporting;
}

sub render_coverage {
    my $self = shift;
    my ($dbh, $run_uuid, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            event_uuid, metadata,
            job_tries.job_try_uuid   AS job_try_uuid,
            test_files.filename      AS test_file,
            source_files.filename    AS source_file,
            source_subs.subname      AS source_sub,
            coverage_manager.package AS coverage_manager
          FROM coverage
          JOIN job_tries        USING(job_try_id)
          JOIN test_files       USING(test_file_id)
          JOIN source_files     USING(source_file_id)
          JOIN source_subs      USING(source_sub_id)
          JOIN coverage_manager USING(coverage_manager_id)
         WHERE run_id = ?
    EOT

    $sth->execute($run_id) or die "Error: " . $dbh->errstr;
    my $coverage = $sth->fetchall_arrayref({});
    return map { $_->{run_uuid} = $run_uuid; $self->parse_date_time($dbh, $_), +{coverage => $_} } @$coverage;
}

sub import_run {
    my $self   = shift;
    my %params = @_;

    my $dbh   = $params{dbh};
    my $cache = $params{cache};
    my $run   = $params{item};

    $run->{user_id}    = $self->get_or_create_id($cache, $dbh, 'users'    => 'user_id',    username => delete $run->{username});
    $run->{project_id} = $self->get_or_create_id($cache, $dbh, 'projects' => 'project_id', name     => delete $run->{project_name});

    $self->insert($dbh, runs => $run);
}

sub import_run_field {
    my $self   = shift;
    my %params = @_;

    my $dbh       = $params{dbh};
    my $cache     = $params{cache};
    my $run_field = $params{item};

    $run_field->{run_id} = $self->get_or_create_id($cache, $dbh, 'runs' => 'run_id', run_uuid => delete $run_field->{run_uuid});

    $self->insert($dbh, run_fields => $run_field);
}

sub import_job {
    my $self = shift;
    my %params = @_;

    my $dbh   = $params{dbh};
    my $cache = $params{cache};
    my $job   = $params{item};

    $job->{run_id}       = $self->get_or_create_id($cache, $dbh, 'runs'       => 'run_id',       run_uuid => delete $job->{run_uuid});
    $job->{test_file_id} = $self->get_or_create_id($cache, $dbh, 'test_files' => 'test_file_id', filename => delete $job->{filename});

    $self->insert($dbh, jobs => $job);
}

sub import_job_try {
    my $self = shift;
    my %params = @_;

    my $dbh   = $params{dbh};
    my $cache = $params{cache};
    my $try   = $params{item};

    $try->{job_id} = $self->get_or_create_id($cache, $dbh, 'jobs' => 'job_id', job_uuid => delete $try->{job_uuid});

    $self->insert($dbh, job_tries => $try);
}

sub import_job_try_field {
    my $self   = shift;
    my %params = @_;

    my $dbh       = $params{dbh};
    my $cache     = $params{cache};
    my $try_field = $params{item};

    $try_field->{job_try_id} = $self->get_or_create_id($cache, $dbh, 'job_tries' => 'job_try_id', job_try_uuid => delete $try_field->{job_try_uuid});

    $self->insert($dbh, job_try_fields => $try_field);
}

sub import_event {
    my $self = shift;
    my %params = @_;

    my $dbh   = $params{dbh};
    my $cache = $params{cache};
    my $event = $params{item};

    $event->{job_try_id} = $self->get_or_create_id($cache, $dbh, 'job_tries' => 'job_try_id', job_try_uuid => delete $event->{job_try_uuid});

    $self->insert($dbh, events => $event);
}

sub import_binary {
    my $self = shift;
    my %params = @_;

    my $dbh    = $params{dbh};
    my $cache = $params{cache};
    my $binary = $params{item};

    $binary->{event_id} = $self->get_or_create_id($cache, $dbh, 'events' => 'event_id', event_uuid => $binary->{job_try_uuid});

    $self->insert($dbh, binaries => $binary);
}

sub import_reporting {
    my $self = shift;
    my %params = @_;

    my $dbh       = $params{dbh};
    my $cache     = $params{cache};
    my $reporting = $params{item};

    $reporting->{job_try_id}   = $self->get_or_create_id($cache, $dbh, 'job_tries'  => 'job_try_id',   job_try_uuid => delete $reporting->{job_try_uuid});
    $reporting->{test_file_id} = $self->get_or_create_id($cache, $dbh, 'test_files' => 'test_file_id', filename     => delete $reporting->{filename});
    $reporting->{project_id}   = $self->get_or_create_id($cache, $dbh, 'projects'   => 'project_id',   name         => delete $reporting->{project_name});
    $reporting->{user_id}      = $self->get_or_create_id($cache, $dbh, 'users'      => 'user_id',      username     => delete $reporting->{username});
    $reporting->{run_id}       = $self->get_or_create_id($cache, $dbh, 'runs'       => 'run_id',       run_uuid     => delete $reporting->{run_uuid});

    $self->insert($dbh, reporting => $reporting);
}

sub import_coverage {
    my $self = shift;
    my %params = @_;

    my $dbh      = $params{dbh};
    my $cache    = $params{cache};
    my $coverage = $params{item};

    $coverage->{job_try_id}          = $self->get_or_create_id($cache, $dbh, 'job_tries'        => 'job_try_id',          job_try_uuid => delete $coverage->{job_try_uuid});
    $coverage->{coverage_manager_id} = $self->get_or_create_id($cache, $dbh, 'coverage_manager' => 'coverage_manager_id', package      => delete $coverage->{coverage_manager});
    $coverage->{run_id}              = $self->get_or_create_id($cache, $dbh, 'runs'             => 'run_id',              run_uuid     => delete $coverage->{run_uuid});
    $coverage->{test_file_id}        = $self->get_or_create_id($cache, $dbh, 'test_files'       => 'test_file_id',        filename     => delete $coverage->{test_file});
    $coverage->{source_file_id}      = $self->get_or_create_id($cache, $dbh, 'source_files'     => 'source_file_id',      filename     => delete $coverage->{source_file});
    $coverage->{source_sub_id}       = $self->get_or_create_id($cache, $dbh, 'source_subs'      => 'source_sub_id',       subname      => delete $coverage->{source_sub});

    $self->insert($dbh, coverage => $coverage);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Sync - Module for dumping, loading, and syncing yath databases

=head1 DESCRIPTION

If you need to migrate data between databases, merge databases, or sync
databases, this is the module for you.

This module will sync the essential data, while re-mapping items that may
already be present in the destination database, such as usernames, test file
names, etc, all of which may have different uuids in the new database.

Care is taken to preserve the uuids of runs, jobs, events, etc.

=head1 SYNOPSIS

    use App::Yath::Schema::Sync;

    my $source_dbh = ...;
    my $dest_dbh   = ...;

    my $sync = App::Yath::Schema::Sync->new();

    my $delta = $sync->run_delta($source_dbh, $dest_dbh);

    # Do the work
    $sync->sync(
        from_dbh => $source_dbh,
        to_dbh   => $dest_dbh,
        run_ids  => $delta->{missing_in_b},

        debug => 1,    # Print a notice for each dumped run_id
    );

=head1 METHODS

=over 4

=item @list = $sync->table_list()

Get a list of tables that can be synced.

=item $run_ids = $sync->get_runs($dbh)

=item $run_ids = $sync->get_runs($jsonl_file)

Get all the run_ids from a database or jsonl file.

=item $delta = $sync->run_delta($dbh_a, $dbh_b)

Get lists of run_ids that exist in only one of the two provided databases.

    {
        missing_in_a => \@run_ids_a,
        missing_in_b => \@run_ids_b,
    }

=item $sync->sync(...)

Copy data from the source database to the destination database.

    $sync->sync(
        from_dbh => $from_dbh,    # Source database
        to_dbh   => $to_dbh,      # Destination database
        run_ids  => \@run_ids,    # list of run_ids to sync

        name  => "",              # Optional name for this operation in debugging/errors
        skip  => {},              # Optional hashref of (TABLE => bool) for tables to skip
        cache => {},              # Optional uuid cache map.
        debug => 0,               # Optional, turn on for verbosity
    );

=item $sync->write_sync(...)

Output the data to jsonl format.

    $sync->write_sync(
        dbh     => $dbh,        # Source database
        run_ids => $run_ids,    # list of run_ids to sync
        wh      => $wh,         # Where to print the jsonl data
        skip    => $skip,       # Optional hashref of (TABLE => bool) for tables to skip
        debug   => 0,           # Optional, turn on for verbosity
    );

=item $sync->read_sync(...)

Read the jsonl data and insert it into the database.

    $sync->read_sync(
        dbh     => $dbh,        # Destination database
        run_ids => $run_ids,    # list of run_ids to sync
        rh      => $rh,         # Where to read the jsonl data
        cache   => $cache,      # Optional uuid cache map.
        debug   => 0,           # Optional, turn on for verbosity
    );

=item $uuid = $sync->get_or_create_id($cache, $dbh, $table, $uuid_field, $value_field, $value)

Create or find a common link in the database (think project, user, etc).

    my $uuid = $sync->get_or_create_id(
        $cache, $dbh,
        users    => 'user_idx',
        username => 'bob',
    );

=item $sync->insert($dbh, $table, $data)

Insert $data as a row into $table.

=back

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

=pod

=cut POD NEEDS AUDIT

