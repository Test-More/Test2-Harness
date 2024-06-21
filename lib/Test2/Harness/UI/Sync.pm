package Test2::Harness::UI::Sync;
use strict;
use warnings;

use DBI;
use Scope::Guard;
use Carp qw/croak/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::UI::UUID qw/uuid_inflate gen_uuid/;

our $VERSION = '0.000144';

use Test2::Harness::UI::Util::HashBase;

sub run_delta {
    my $self = shift;
    my ($dbh_a, $dbh_b) = @_;

    my $refa = ref($dbh_a);
    my $refb = ref($dbh_b);

    my $a_runs = $refa eq 'ARRAY' ? $dbh_a : $self->get_runs($dbh_a);
    my $b_runs = $refb eq 'ARRAY' ? $dbh_b : $self->get_runs($dbh_b);

    my %map_a = map {($_ => 1)} @$a_runs;
    my %map_b = map {($_ => 1)} @$b_runs;

    return {
        missing_in_a => [grep { !$map_a{$_} } @$b_runs],
        missing_in_b => [grep { !$map_b{$_} } @$a_runs],
    };
}

sub sync {
    my $self = shift;
    my %params = @_;

    my $from_dbh = $params{from_dbh} or croak "Need a DBH to pull data (from_dbh)";
    my $to_dbh   = $params{to_dbh}   or croak "Need a DBH to push data TO (to_dbh)";
    my $run_ids  = $params{run_ids}  or croak "Need a list of run_id's to sync";

    my $name  = $params{name}  // "$from_dbh -> $to_dbh";
    my $skip  = $params{skip}  // {};
    my $cache = $params{cache} // {};
    my $debug = $params{debug} // 0;

    my $from_uuidf = $params{from_uuid_format} // 'binary';
    my $to_uuidf   = $params{to_uuid_format}   // 'binary';

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
            dbh     => $to_dbh,
            run_ids => $run_ids,
            rh      => $rh,
            cache   => $cache,
            debug   => $debug,
            uuidf   => $to_uuidf,
        );

        $guard->dismiss();

        exit 0;
    }

    close($rh);
    $self->write_sync(
        dbh     => $from_dbh,
        run_ids => $run_ids,
        wh      => $wh,
        skip    => $skip,
        debug   => $debug,
        uuidf   => $from_uuidf,
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

    return $self->_get_jsonl_runs($dbh_or_file)
        if $dbh_or_file =~ m/\.jsonl$/ && -f $dbh_or_file;

    return $self->_get_dbh_runs($dbh_or_file);
}

sub _get_jsonl_runs {
    my $self = shift;
    my ($file) = @_;

    my $runs = [];

    open(my $fh, '<', $file) or croak "Could not open file '$file' for reading: $!";
    while (my $line = <$fh>) {
        # We only care about lines that start with this, the format does not allow this to false-positive
        next unless $line =~ m/\{"run":\{.*"run_id":"([^"]+)"/;
        push @$runs => $1;
    }
    close($fh);

    return $runs;
}

sub _get_dbh_runs {
    my $self = shift;
    my ($dbh) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT run_id
        FROM   runs
        WHERE  status NOT IN ('pending', 'running', 'broken')
        ORDER  BY added ASC
    EOT

    $sth->execute() or die "MySQL Error: " . $dbh->errstr;

    my @out;

    while (my $run = $sth->fetchrow_arrayref()) {
        push @out => uuid_inflate($run->[0])->string;
    }

    return \@out;
}

sub table_list { qw/runs run_fields jobs job_fields events binaries reporting coverage/ }

sub write_sync {
    my $self = shift;
    my %params = @_;

    my $dbh     = $params{dbh}     or croak "'dbh' is required";
    my $run_ids = $params{run_ids} or croak "'run_ids' must be an arrayref of run ids";
    my $wh      = $params{wh}      or croak "'wh' is required and must be a writable filehandle";
    my $uuidf   = $params{uuidf} // 'binary';
    my $skip    = $params{skip}  // {};
    my $debug   = $params{debug} // 0;

    my @to_dump;
    for my $table ($self->table_list) {
        next if $skip->{$table};
        push @to_dump => "render_${table}";
    }

    $wh->autoflush(1);

    STDOUT->autoflush(1);

    my $total = @$run_ids;
    my $counter = 0;
    my $subcount = 0;
    for my $run_id (@$run_ids) {
        my $run_uuid = uuid_inflate($run_id)->$uuidf;
        my @args = ($dbh, $run_uuid, $skip);

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
            print "  Dumped run $counter/$total: $run_id\n";
        }
    }

    return;
}

sub read_sync {
    my $self = shift;
    my %params = @_;

    my $dbh     = $params{dbh}     or croak "'dbh' is required";
    my $run_ids = $params{run_ids} or croak "'run_ids' must be an arrayref of run ids";
    my $rh      = $params{rh}      or croak "'rh' is required and must be a readable filehandle";
    my $uuidf   = $params{uuidf} // 'binary';
    my $cache   = $params{cache} // {};
    my $debug   = $params{debug} // 0;

    $dbh->{AutoCommit} = 0;

    my %include = map {($_ => 1)} @$run_ids;
    my $total = @$run_ids;
    my $counter = 0;
    my $last_run_id;
    my $broken;
    while (my $line = <$rh>) {
        my $data = decode_json($line);

        my ($type, @bad) = keys %$data;
        die "Invalid data!" if @bad;

        if ($type eq 'run') {
            $dbh->commit();
            $dbh->{AutoCommit} = 0;

            if ($debug && $last_run_id) {
                if ($broken) {
                    print "  BROKEN run $counter/$total: $last_run_id\n";
                }
                else {
                    print "Imported run $counter/$total: $last_run_id\n";
                }
            }

            $broken = undef;
            my $new_run_id = $data->{$type}->{run_id};

            if ($new_run_id && !$include{$new_run_id}) {
                $last_run_id = undef;
                next;
            }

            $last_run_id = $new_run_id;
            $counter++;
        }

        next if $broken;
        next unless $last_run_id;

        my $method = "import_$type";

        next if eval {
            $self->$method(dbh => $dbh, item => $data->{$type}, uuidf => $uuidf, cache => $cache);
            1;
        };

        $dbh->rollback();
        $broken = $last_run_id;
    }

    $dbh->commit();
    $dbh->disconnect();

    return;
}

sub get_or_create_id {
    my $self = shift;
    my ($cache, $dbh, $uuidf, $table, $field, $via_field, $via_value) = @_;

    return undef unless $via_value;

    return $cache->{$table}{$via_field}{$via_value}{$field} //= $self->_get_or_create_id(@_);
}

sub _get_or_create_id {
    my $self = shift;
    my ($cache, $dbh, $uuidf, $table, $field, $via_field, $via_value) = @_;

    my $sql = "SELECT $field FROM $table WHERE $via_field = ?";

    my $sth = $dbh->prepare($sql);
    $sth->execute($via_value) or die "MySQL Error: " . $dbh->errstr;
    if ($sth->rows) {
        my $row = $sth->fetchrow_hashref();
        return uuid_inflate($row->{$field})->string;
    }

    my $uuid = gen_uuid();
    $self->insert($dbh, $uuidf, $table, {$field => $uuid, $via_field => $via_value});
    return $uuid->string;
}

sub insert {
    my $self = shift;
    my ($dbh, $uuidf, $table, $data) = @_;

    _fix_uuids($uuidf => $data);

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

sub stringify_uuids {
    my ($in) = @_;
    _fix_uuids(string => $in);
}

sub binarify_uuids {
    my ($in) = @_;
    _fix_uuids(binary => $in);
}

my @ID_FIELDS = qw{
    coverage_id
    coverage_manager_id
    event_id
    job_field_id
    job_id
    job_key
    parent_id
    project_id
    reporting_id
    run_field_id
    run_id
    source_file_id
    source_sub_id
    test_file_id
    user_id
};

sub _fix_uuids {
    my ($method => $in) = @_;
    return unless $in;
    my $type = ref($in);

    if (!$type) {
        return uuid_inflate($in)->$method;
    }
    if ($type eq 'Test2::Harness::UI::UUID') {
        return $in->$method;
    }
    if ($type eq 'HASH') {
        # Cannot do all_id or _key fields, some are not uuids...
        # This is a list of safe ones
        for my $key (@ID_FIELDS) {
            next unless exists $in->{$key};
            $in->{$key} = _fix_uuids($method, $in->{$key});
        }
    }
    elsif($type eq 'ARRAY') {
        _fix_uuids($method, $_) for @$in;
    }
    else {
        die "Unsupported type '$type' '$in'";
    }

    return $in;
}

sub render_runs {
    my $self = shift;
    my ($dbh, $run_id, $skip) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
            run_id, status, worker_id, error, added, duration, mode, buffer,
            passed, failed, retried, concurrency, parameters, has_coverage,
            users.username, projects.name as project_name
        FROM runs
        JOIN users    USING(user_id)
        JOIN projects USING(project_id)
        WHERE run_id = ?
    EOT

    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;

    my $run = stringify_uuids($sth->fetchrow_hashref());
    delete $run->{has_coverage} if $skip->{coverage};

    return {run => $run};
}

sub render_run_fields {
    my $self = shift;
    my ($dbh, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT run_id, run_field_id, name, data, details, raw, link
          FROM run_fields
         WHERE run_id = ?
    EOT
    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;
    my $run_fields = stringify_uuids($sth->fetchall_arrayref({}));

    return map { +{run_field => $_} } @$run_fields;
}

sub render_jobs {
    my $self = shift;
    my ($dbh, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
                run_id, job_key, job_id, job_try, job_ord, is_harness_out, status, parameters, fields, name, fail, retry,
                exit_code, launch, start, ended, duration, pass_count, fail_count,
                test_files.filename
          FROM jobs
          JOIN test_files USING (test_file_id)
         WHERE run_id = ?
    EOT

    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;
    my $jobs = stringify_uuids($sth->fetchall_arrayref({}));
    return map { +{job => $_} } @$jobs;
}

sub render_job_fields {
    my $self = shift;
    my ($dbh, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT job_field_id, job_key, job_fields.name as name, data, details, raw, link
          FROM job_fields
          JOIN jobs USING(job_key)
         WHERE run_id = ?
    EOT

    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;
    my $job_fields = stringify_uuids($sth->fetchall_arrayref({}));
    return map { +{job_field => $_} } @$job_fields;
}

sub render_events {
    my $self = shift;
    my ($dbh, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT events.*
          FROM events
          JOIN jobs USING(job_key)
         WHERE run_id = ?
           AND is_subtest = TRUE
    EOT

    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;
    my $events = stringify_uuids($sth->fetchall_arrayref({}));
    return map { +{event => $_} } @$events;
}

sub render_binaries {
    my $self = shift;
    my ($dbh, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT binaries.*
          FROM binaries
          JOIN events USING(event_id)
          JOIN jobs USING(job_key)
         WHERE run_id = ?
           AND is_subtest = TRUE
    EOT

    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;
    my $binaries = stringify_uuids($sth->fetchall_arrayref({}));
    return map { +{binary => $_} } @$binaries;
}

sub render_reporting {
    my $self = shift;
    my ($dbh, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
                reporting_id, run_id, run_ord, job_try, subtest, duration, fail, pass, retry, abort, job_key, event_id,
                projects.name AS project_name,
                users.username AS username,
                test_files.filename AS filename
          FROM reporting
          JOIN projects   USING(project_id)
          JOIN users      USING(user_id)
          JOIN test_files USING(test_file_id)
         WHERE run_id = ?
    EOT
    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;
    my $reporting = stringify_uuids($sth->fetchall_arrayref({}));
    return map { +{reporting => $_} } @$reporting;
}

sub render_coverage {
    my $self = shift;
    my ($dbh, $run_id) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT
                coverage_id, run_id, job_key, metadata,
                test_files.filename AS test_file,
                source_files.filename AS source_file,
                source_subs.subname AS source_sub,
                coverage_manager.package AS coverage_manager
          FROM coverage
          JOIN test_files       USING(test_file_id)
          JOIN source_files     USING(source_file_id)
          JOIN source_subs      USING(source_sub_id)
          JOIN coverage_manager USING(coverage_manager_id)
         WHERE run_id = ?
    EOT

    $sth->execute($run_id) or die "MySQL Error: " . $dbh->errstr;
    my $coverage = stringify_uuids($sth->fetchall_arrayref({}));
    return map { +{coverage => $_} } @$coverage;
}

sub import_run {
    my $self   = shift;
    my %params = @_;

    my $dbh   = $params{dbh};
    my $uuidf = $params{uuidf};
    my $cache = $params{cache};
    my $run   = $params{item};

    $run->{user_id}    = $self->get_or_create_id($cache, $dbh, $uuidf, 'users'    => 'user_id',    username => delete $run->{username});
    $run->{project_id} = $self->get_or_create_id($cache, $dbh, $uuidf, 'projects' => 'project_id', name     => delete $run->{project_name});

    $self->insert($dbh, $uuidf, runs => $run);
}

sub import_run_field {
    my $self   = shift;
    my %params = @_;

    my $dbh       = $params{dbh};
    my $uuidf     = $params{uuidf};
    my $run_field = $params{item};

    $self->insert($dbh, $uuidf, run_fields => $run_field);
}

sub import_job {
    my $self = shift;
    my %params = @_;

    my $dbh   = $params{dbh};
    my $uuidf = $params{uuidf};
    my $cache = $params{cache};
    my $job   = $params{item};

    $job->{test_file_id} = $self->get_or_create_id($cache, $dbh, $uuidf, 'test_files' => 'test_file_id', filename => delete $job->{filename});

    $self->insert($dbh, $uuidf, jobs => $job);
}

sub import_job_field {
    my $self   = shift;
    my %params = @_;

    my $dbh       = $params{dbh};
    my $uuidf     = $params{uuidf};
    my $job_field = $params{item};

    $self->insert($dbh, $uuidf, job_fields => $job_field);
}

sub import_event {
    my $self = shift;
    my %params = @_;

    my $dbh   = $params{dbh};
    my $uuidf = $params{uuidf};
    my $event = $params{item};

    $self->insert($dbh, $uuidf, events => $event);
}

sub import_binary {
    my $self = shift;
    my %params = @_;

    my $dbh    = $params{dbh};
    my $uuidf  = $params{uuidf};
    my $binary = $params{item};

    $self->insert($dbh, $uuidf, binaries => $binary);
}

sub import_reporting {
    my $self = shift;
    my %params = @_;

    my $dbh       = $params{dbh};
    my $uuidf     = $params{uuidf};
    my $cache     = $params{cache};
    my $reporting = $params{item};

    $reporting->{project_id}   = $self->get_or_create_id($cache, $dbh, $uuidf, 'projects'   => 'project_id',   name     => delete $reporting->{project_name});
    $reporting->{user_id}      = $self->get_or_create_id($cache, $dbh, $uuidf, 'users'      => 'user_id',      username => delete $reporting->{username});
    $reporting->{test_file_id} = $self->get_or_create_id($cache, $dbh, $uuidf, 'test_files' => 'test_file_id', filename => delete $reporting->{filename});

    $self->insert($dbh, $uuidf, reporting => $reporting);
}

sub import_coverage {
    my $self = shift;
    my %params = @_;

    my $dbh      = $params{dbh};
    my $uuidf    = $params{uuidf};
    my $cache    = $params{cache};
    my $coverage = $params{item};

    $coverage->{test_file_id}        = $self->get_or_create_id($cache, $dbh, $uuidf, 'test_files'       => 'test_file_id',        filename => delete $coverage->{test_file});
    $coverage->{source_file_id}      = $self->get_or_create_id($cache, $dbh, $uuidf, 'source_files'     => 'source_file_id',      filename => delete $coverage->{source_file});
    $coverage->{source_sub_id}       = $self->get_or_create_id($cache, $dbh, $uuidf, 'source_subs'      => 'source_sub_id',       subname  => delete $coverage->{source_sub});
    $coverage->{coverage_manager_id} = $self->get_or_create_id($cache, $dbh, $uuidf, 'coverage_manager' => 'coverage_manager_id', package  => delete $coverage->{coverage_manager});

    $self->insert($dbh, $uuidf, coverage => $coverage);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Sync - Module for dumping, loading, and syncing yathui databases

=head1 DESCRIPTION

If you need to migrate data between databases, merge databases, or sync
databases, this is the module for you.

This module will sync the essential data, while re-mapping items that may
already be present in the destination database, such as usernames, test file
names, etc, all of which may have different uuids in the new database.

Care is taken to preserve the uuids of runs, jobs, events, etc.

=head1 SYNOPSIS

    use Test2::Harness::UI::Sync;

    my $source_dbh = ...;
    my $dest_dbh   = ...;

    my $sync = Test2::Harness::UI::Sync->new();

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

        from_uuid_format => 'binary',    # Defaults to 'binary' may be 'string' for older databases
        to_uuid_format   => 'binary',    # Defaults to 'binary' may be 'string' for older databases
    );

=item $sync->write_sync(...)

Output the data to jsonl format.

    $sync->write_sync(
        dbh     => $dbh,        # Source database
        run_ids => $run_ids,    # list of run_ids to sync
        wh      => $wh,         # Where to print the jsonl data
        uuidf   => $uuidf,      # UUID format, defaults to 'binary', 'string' is also valid.
        skip    => $skip,       # Optional hashref of (TABLE => bool) for tables to skip
        debug   => 0,           # Optional, turn on for verbosity
    );

=item $sync->read_sync(...)

Read the jsonl data and insert it into the database.

    $sync->read_sync(
        dbh     => $dbh,        # Destination database
        run_ids => $run_ids,    # list of run_ids to sync
        rh      => $rh,         # Where to read the jsonl data
        uuidf   => $uuidf,      # UUID format, defaults to 'binary', 'string' is also valid.
        cache   => $cache,      # Optional uuid cache map.
        debug   => 0,           # Optional, turn on for verbosity
    );

=item $uuid = $sync->get_or_create_id($cache, $dbh, $uuidf, $table, $uuid_field, $value_field, $value)

Create or find a common link in the database (think project, user, etc).

    my $uuid = $sync->get_or_create_id(
        $cache, $dbh, 'binary',
        users    => 'user_id',
        username => 'bob',
    );

=item $sync->insert($dbh, $uuidf, $table, $data)

Insert $data as a row into $table using the $uuidf uuid format.

=item $sync->stringify_uuids($thing)

Takes a string or nested data structure, will convert uuid's in id fields to the string form.

=item $sync->binarify_uuids($thing)

Takes a string or nested data structure, will convert uuid's in id fields to the binary form.

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

Copyright 2023 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
