package App::Yath::Schema::RunProcessor;
use strict;
use warnings;
use utf8;

our $VERSION = '2.000005';

use DateTime;
use Data::Dumper;

use List::Util qw/first min max/;
use Time::HiRes qw/time sleep/;
use MIME::Base64 qw/decode_base64/;
use Scalar::Util qw/weaken/;

use Carp qw/croak confess/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use App::Yath::Schema::Config;

use App::Yath::Schema::Util qw/format_duration is_invalid_subtest_name schema_config_from_settings format_uuid_for_db/;
use Test2::Util::UUID qw/gen_uuid/;
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

    <running
    <disconnect_retry

    <mode
    signal

    <id_cache
    <file_cache

    <resource_ord

    <run <run_id <run_uuid
    <jobs
    +job0 +job0_uuid +job0_id +job0_try
    +user +user_id +user_name
    +project +project_id +project_name

    <first_stamp <last_stamp <duration

    <interval <last_flush
    <buffer_size

    <done
    <errors

    <resources
    <coverage
    <reporting
    <run_fields <run_delta
    <try_fields
};

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
        my $run_uuid = $self->{+RUN_UUID} // croak "either 'run' or 'run_uuid' must be provided";
        my $mode     = $self->{+MODE}     // croak "'mode' is a required attribute unless 'run' is specified";
        $self->{+MODE} = $MODES{$mode} // croak "Invalid mode '$mode'";

        my $schema = $self->schema;
        my $run    = $schema->resultset('Run')->create({
            run_uuid   => format_uuid_for_db($run_uuid),
            user_id    => $self->user_id,
            project_id => $self->project_id,
            mode       => $mode,
            status     => 'pending',
        });

        $self->{+RUN} = $run;
    }

    $run->discard_changes;

    $self->{+PROJECT_ID} //= $run->project_id;

    confess "No project id?!?" unless $self->{+PROJECT_ID};

    $self->{+ID_CACHE} = {};

    $self->{+RESOURCE_ORD} //= 1;

    $self->{+COVERAGE}   = [];
    $self->{+RESOURCES}  = [];
    $self->{+REPORTING}  = [];
    $self->{+RUN_FIELDS} = [];
    $self->{+TRY_FIELDS} = [];

    $self->{+BUFFER_SIZE} //= 100;
}

sub process_stdin {
    my $class = shift;
    my ($settings) = @_;

    return $class->process_handle(\*STDIN, $settings);
}

sub process_csnb {
    my $class = shift;
    my ($settings, %params) = @_;

    require Consumer::NonBlock;
    my $r = Consumer::NonBlock->reader_from_env();

    my $cb = $class->process_lines($settings);

    my ($sln);
    if ($params{sl_start} && $params{sl_end}) {
        $sln = $params{sl_start};
        STDOUT->autoflush(1);
        print "\e[s\e[${sln}H\e[KYath DB Upload processing event: 0\e[u";
    }

    my $ln = 0;
    while (1) {
        my $line = $r->read_line;
        $ln++;
        print "\e[s\e[${sln}H\e[KYath DB Upload processing event: $ln\e[u" if $sln;
        $cb->($line);
        last unless $line;
    }
}

sub process_handle {
    my $class = shift;
    my ($fh, $settings) = @_;

    my $cb = $class->process_lines($settings);

    while (1) {
        my $line = <$fh>;
        $cb->($line);
        last unless $line;
    }
}

sub process_lines {
    my $class = shift;
    my ($settings, %params) = @_;

    my $done = 0;
    my $idx = 1;
    my ($next, $last, $run);
    return sub {
        my $line = shift;

        croak "Call to process lines callback after an undef line" if $done;

        if (!defined($line)) {
            $done++;
            $last->();
        }
        elsif ($next) {
            $next->($line, $idx++);
        }
        else {
            ($next, $last, $run) = $class->_process_first_line($line, $idx++, $settings, %params);
        }

        return $run;
    };
}

sub _process_first_line {
    my $class = shift;
    my ($line, $idx, $settings, %params) = @_;

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
    my ($run_id, $run_uuid);
    if (my $runf = $f->{harness_run}) {
        $run_uuid = $runf->{run_id} or die "No run-uuid?";

        my $pub = $settings->group('publish') or die "No publish settings";

        # Legacy logs
        $runf->{settings} //= delete $f->{harness_settings};

        my $proj = $runf->{settings}->{yath}->{project} || $params{project} || $settings->yath->project or die "Project name could not be determined";
        my $user = $pub->user // $settings->yath->user // $ENV{USER};

        my $p = $config->schema->resultset('Project')->find_or_create({name => $proj});
        my $u = $config->schema->resultset('User')->find_or_create({username => $user, role => 'user'});

        if (my $old = $config->schema->resultset('Run')->find({run_uuid => format_uuid_for_db($run_uuid)})) {
            die "Run with uuid '$run_uuid' is already published. Use --publish-force to override it." unless $settings->publish->force;
            $old->delete;
        }

        $run = $config->schema->resultset('Run')->create({
            run_uuid   => format_uuid_for_db($run_uuid),
            canon      => 1,
            mode       => $pub->mode,
            status     => 'pending',
            user_id    => $u->user_id,
            project_id => $p->project_id,
        });

        $run_id = $run->run_id;

        $self = $class->new(
            settings     => $settings,
            config       => $config,
            run          => $run,
            run_id       => $run_id,
            run_uuid     => $run_uuid,
            interval     => $pub->flush_interval,
            buffer_size  => $pub->buffer_size,
            user         => $u,
            user_id      => $u->user_id,
            project      => $p,
            project_id   => $p->project_id,
        );

        $self->start();
        $self->process_event($e, $f, $idx);
    }
    else {
        die "First event did not contain run data";
    }

    my $links;
    if ($settings->check_group('webclient')) {
        if (my $url = $settings->webclient->url) {
            $links = "\nThis run can be reviewed at: $url/view/$run_id\n\n";
            print STDOUT $links if $params{print_links};
        }
    }

    my $int = $SIG{INT};
    my $term = $SIG{TERM};

    $SIG{INT}  = sub { $self->set_signal('INT');  die "Caught Signal 'INT'\n"; };
    $SIG{TERM} = sub { $self->set_signal('TERM'); die "Caught Signal 'TERM'\n"; };

    my @errors;
    $self->{+ERRORS} = \@errors;

    return (
        sub {
            my ($line, $idx) = @_;

            return if eval {
                my $e = decode_json($line);
                $self->process_event($e, undef, $idx);
                1;
            };
            my $err = $@;

            warn "Error sending event(s) to database:\n====\n$err\n====\n";

            push @errors => $err;
            die $err if $self->{+SIGNAL};
        },
        sub {
            $self->finish(@errors);
            print STDOUT $links if $links && $params{print_links};

            $SIG{INT} = $int;
            $SIG{TERM} = $term;
        },
        $run,
    );
}

sub retry_on_disconnect {
    my $self = shift;
    my ($description, $callback, $on_exception) = @_;

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

    $on_exception->() if $on_exception;
    print STDERR qq{Failed "$description" (attempt $attempt)\n$err\n};
    exit(0);
}

sub populate {
    my $self = shift;
    my ($type, $data) = @_;

    return unless $data && @$data;

    local $ENV{DBIC_DT_SEARCH_OK} = 1;

    $self->retry_on_disconnect(
        "Populate '$type'",
        sub {
            no warnings 'once';
            local $Data::Dumper::Sortkeys = 1;
            local $Data::Dumper::Freezer = 'T2HarnessFREEZE';
            local *DateTime::T2HarnessFREEZE = sub { my $x = $_[0]->ymd . " " . $_[0]->hms; $_[0] = \$x };
            my $rs = $self->schema->resultset($type);
            my $ok = eval { $rs->populate($data); 1 };
            my $err = $@;
            return 1 if $ok;

            die $err unless $err =~ m/duplicate/i;

            warn "\nDuplicate found:\n====\n$err\n====\n\nPopulating '$type' 1 at a time.\n";
            for my $item (@$data) {
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
    my $self  = shift;
    my $stamp = shift;
    return undef unless $stamp;

    unless (ref($stamp)) {
        my $recalc = 0;
        if (!$self->{+FIRST_STAMP} || $self->{+FIRST_STAMP} > $stamp) {
            $self->{+FIRST_STAMP} = $stamp;
            $recalc = 1;
        }

        if (!$self->{+LAST_STAMP} || $self->{+LAST_STAMP} < $stamp) {
            $self->{+LAST_STAMP} = $stamp;
            $recalc = 1;
        }

        $self->{+DURATION} = $self->{+LAST_STAMP} - $self->{+FIRST_STAMP} if $recalc;
    }

    return DateTime->from_epoch(epoch => $stamp, time_zone => 'local');
}

sub job0_uuid {
    my $self = shift;
    return $self->{+JOB0_UUID} //= $self->job0->{job_uuid};
}

sub job0_id {
    my $self = shift;
    return $self->{+JOB0_ID} //= $self->job0->{job_id};
}

sub job0_try {
    my $self = shift;
    return $self->{+JOB0_TRY} //= $self->get_job_try($self->job0, 0);
}

sub job0 {
    my $self = shift;
    return $self->{+JOB0} //= $self->get_job($self->{+JOB0_UUID} //= gen_uuid());
}

sub user {
    my $self = shift;

    return $self->{+USER} if $self->{+USER};
    return $self->{+USER} = $self->{+RUN}->user if $self->{+RUN};

    my $schema = $self->schema;

    if (my $user_id = $self->{+USER_ID}) {
        my $user = $schema->resultset('User')->find({user_id => $user_id}) or confess "Invalid user id: $user_id";
        return $self->{+USER} = $user;
    }

    if (my $username = $self->{+USER_NAME}) {
        my $user = $schema->resultset('User')->find({username => $username}) or confess "Invalid user name: $username";
        return $self->{+USER} = $user;
    }

    confess "No user, user_name, or user_id specified";
}

sub user_id {
    my $self = shift;
    return $self->{+USER_ID} //= $self->user->user_id;
}

sub user_name {
    my $self = shift;
    return $self->{+USER_NAME} //= $self->user->username;
}

sub project {
    my $self = shift;

    return $self->{+PROJECT} if $self->{+PROJECT};
    return $self->{+PROJECT} = $self->{+RUN}->project if $self->{+RUN};

    my $schema = $self->schema;

    if (my $project_id = $self->{+PROJECT_ID}) {
        my $project = $schema->resultset('Project')->find({project_id => $project_id}) or confess "Invalid project id: $project_id";
        return $self->{+PROJECT} = $project;
    }

    if (my $name = $self->{+PROJECT_NAME}) {
        my $project = $schema->resultset('Project')->find({projectname => $name}) or confess "Invalid project name: $name";
        return $self->{+PROJECT} = $project;
    }

    confess "No project, project_name, or project_id specified";
}

sub project_id {
    my $self = shift;
    return $self->{+PROJECT_ID} //= $self->project->project_id;
}

sub project_name {
    my $self = shift;
    return $self->{+PROJECT_NAME} //= $self->project->name;
}

sub start {
    my $self = shift;
    return if $self->{+RUNNING};

    $self->retry_on_disconnect("update status" => sub { $self->{+RUN}->update({status => 'running'}) });

    $self->{+RUNNING} = 1;
}

sub get_job {
    my $self = shift;
    my ($job_uuid, %params) = @_;

    my $is_harness_out = 0;

    my $test_file_id;

    if (!$job_uuid || $job_uuid eq '0' || $job_uuid eq $self->{+JOB0_UUID}) {
        $job_uuid = $self->job0_uuid;
        $is_harness_out = 1;
        $test_file_id = $self->get_test_file_id('HARNESS INTERNAL LOG');
    }

    my $run_id = $self->{+RUN}->run_id;
    my $job_try = $params{job_try} // 0;

    if (my $job = $self->{+JOBS}->{$job_uuid}) {
        return $job;
    }

    my $result;

    $test_file_id //= $self->{+FILE_CACHE}->{$job_uuid};

    for my $spec ($params{queue}, $params{job_spec}) {
        last if $test_file_id;
        next unless $spec;

        my $file = $spec->{rel_file} // $spec->{file};
        $test_file_id = $self->get_test_file_id($file) if $file;
        $self->{+FILE_CACHE}->{$job_uuid} = $test_file_id;
    }

    die "Could not find a test file name or id" unless $test_file_id;

    $self->retry_on_disconnect(
        "vivify job" => sub {
            $result = $self->schema->resultset('Job')->update_or_create({
                job_uuid       => format_uuid_for_db($job_uuid),
                run_id         => $run_id,
                test_file_id   => $test_file_id,
                is_harness_out => $is_harness_out,
                passed         => undef,
                failed         => 0,
            });
        }
    );

    my $job_id = $result->job_id;

    my $job = {
        run_id       => $run_id,
        job_id       => $job_id,
        job_uuid     => $job_uuid,
        test_file_id => $test_file_id,

        is_harness_out => $is_harness_out,

        tries => [],

        result => $result,
    };

    return $self->{+JOBS}->{$job_uuid} = $job;
}

sub get_job_try {
    my $self = shift;
    my ($job, $try_ord) = @_;

    $try_ord //= 0;

    if (my $try = $job->{tries}->[$try_ord]) {
        return $try;
    }

    my $result;
    $self->retry_on_disconnect(
        "vivify job try" => sub {
            $result = $self->schema->resultset('JobTry')->update_or_create({
                job_try_uuid => format_uuid_for_db(gen_uuid()),
                job_id       => $job->{job_id},
                job_try_ord  => $try_ord,
            });
        }
    );

    my $try = {
        job_try_uuid => $result->job_try_uuid,
        job_try_id   => $result->job_try_id,
        job_try_ord  => $try_ord,
        result       => $result,

        orphan_events => {},
        ready_events  => [],

        job      => $job,
        run_id   => $job->{run_id},
        job_id   => $job->{job_id},
        job_uuid => $job->{job_uuid},
    };

    weaken($try->{job});

    return $job->{tries}->[$try_ord] = $try
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

sub _get__id {
    my $self = shift;
    my ($type, $id_field, $field, $id) = @_;

    return undef unless $id;

    return $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id}
        if $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id};

    my $spec = {$field => $id};

    # id fields are always auto-increment, uuid is always uuid
    $spec->{$id_field} = gen_uuid() if $id_field =~ m/_uuid$/;

    my $result = $self->schema->resultset($type)->find_or_create($spec);

    return $self->{+ID_CACHE}->{$type}->{$id_field}->{$field}->{$id} = $result->$id_field;
}

sub get_test_file_id {
    my $self = shift;
    my ($file) = @_;

    return undef unless $file;

    my @parts = split /(\/t2?\/)/, $file;
    my $new;
    while (my $part = shift @parts) {
        if ($part =~ m{/(t2?)/} && !$new) {
            $new = "$1/";
            next;
        }

        next unless $new;

        $new .= $part;
    }

    $file = $new if $new;

    $file =~ s{^\.+/+}{};

    return $self->_get__id('TestFile' => 'test_file_id', filename => $file);
}

sub _pull_facet_binaries {
    my $self = shift;
    my ($f, $params) = @_;

    my $bin = $f->{binary} or return undef;
    return undef unless @$bin;

    my $e_uuid = $params->{e_uuid};
    my @binaries;

    for my $file (@$bin) {
        my $data = delete $file->{data};
        $file->{data} = 'Extracted to the "binaries" table';

        push @binaries => {
            event_uuid  => format_uuid_for_db($e_uuid),
            filename    => $file->{filename},
            description => $file->{details},
            data        => decode_base64($data),
            is_image    => $file->{is_image} // $file->{filename} =~ m/\.(a?png|gif|jpe?g|svg|bmp|ico)$/ ? 1 : 0,
        };
    }

    return undef unless @binaries;
    return \@binaries;
}

sub _pull_facet_resource {
    my $self = shift;
    my ($f, $params) = @_;

    my $resf = $f->{resource_state} or return undef;
    my $data = delete $resf->{data};
    $resf->{data} = 'Extracted to the "resources" table';

    my $ord    = $self->{+RESOURCE_ORD}++;
    my $mod    = $resf->{module};
    my $host   = $resf->{host};
    my $e_uuid = $params->{e_uuid};
    my $stamp  = $self->format_stamp($f->{harness}->{stamp});

    my $resource_type_id = $self->_get__id(ResourceType => 'resource_type_id', name     => $mod)  or die "Could not get resource_type id";
    my $host_id          = $self->_get__id(Host         => 'host_id',          hostname => $host) or die "Could not get host id";

    push @{$self->{+RESOURCES} //= []} => {
        run_id           => $self->{+RUN_ID},
        host_id          => $host_id,
        resource_type_id => $resource_type_id,
        resource_ord     => $ord,
        event_uuid       => format_uuid_for_db($e_uuid),
        data             => encode_json($data),
        stamp            => $stamp,
    };
}

sub _pull_facet_run_coverage {
    my $self = shift;
    my ($f, $params) = @_;
    my $c = $self->_pull_facet__coverage($f, 'run', $params);

    my $files  = $c->{files};
    my $meta   = $c->{testmeta};

    my $try    = $params->{try};
    my $e_uuid = $params->{e_uuid};

    for my $source (keys %$files) {
        my $subs = $files->{$source};
        for my $sub (keys %$subs) {
            my $tests = $subs->{$sub};
            for my $test (keys %$tests) {
                push @{$self->{+COVERAGE} //= []} => $self->_pre_process_coverage(
                    event_uuid => $e_uuid,
                    test       => $test,
                    source     => $source,
                    sub        => $sub,
                    manager    => $meta->{$test}->{manager},
                    meta       => $tests->{$test}
                );
            }
        }
    }

    return;
}

sub _pre_process_coverage {
    my $self   = shift;
    my %params = @_;

    my $e_uuid = $params{event_uuid};
    my $test_id = $self->get_test_file_id($params{test}) or confess("Could not get test id (for '$params{test}')");

    my $source_id  = $self->_get__id(SourceFile      => 'source_file_id',      filename => $params{source}) or die "Could not get source id";
    my $sub_id     = $self->_get__id(SourceSub       => 'source_sub_id',       subname  => $params{sub})    or die "Could not get sub id";
    my $manager_id = $self->_get__id(CoverageManager => 'coverage_manager_id', package  => $params{manager});

    return {
        run_id              => $self->{+RUN_ID},
        event_uuid          => format_uuid_for_db($e_uuid),
        test_file_id        => $test_id,
        source_file_id      => $source_id,
        source_sub_id       => $sub_id,
        coverage_manager_id => $manager_id,

        $manager_id         ? (metadata   => encode_json($params{meta})) : (),
        $params{job_try_id} ? (job_try_id => $params{job_try_id})              : (),
    };
}

sub _pull_facet_job_try_coverage {
    my $self = shift;
    my ($f, $params) = @_;
    my $c = $self->_pull_facet__coverage($f, 'job', $params);

    my $job    = $params->{job};
    my $try    = $params->{try};
    my $e_uuid = $params->{e_uuid};

    for my $source (keys %{$c->{files}}) {
        my $subs = $c->{files}->{$source};
        for my $sub (keys %$subs) {
            my $test = $c->{test} // $job->{result}->file;

            push @{$self->{+COVERAGE} //= []} => $self->_pre_process_coverage(
                event_uuid => $e_uuid,
                job_try_id => $try->{job_try_id},
                test       => $test,
                source     => $source,
                sub        => $sub,
                manager    => $c->{manager},
                meta       => $subs->{$sub},
            );
        }
    }

    return;
}

sub _pull_facet__coverage {
    my $self = shift;
    my ($f, $type, $params) = @_;
    my $e_uuid = $params->{e_uuid};

    my $c = delete $f->{"${type}_coverage"} or return undef;

    $f->{"${type}_coverage"} = 'Extracted to the "coverage" table';
    return $c;
}

sub _pull_facet_children {
    my $self = shift;
    my ($f, $params) = @_;

    my $p = $f->{parent} or return undef;
    my $c = $p->{children} or return undef;
    return undef unless @$c;
    $f->{parent}->{children} = 'Extracted to populate "events" table';

    return $c;
}

sub _pull_facet__fields {
    my $self = shift;
    my ($f, $type, $params) = @_;

    my @fields;
    if (my $fs = $f->{"${type}_fields"}) {
        push @fields => @{$fs};
        $f->{"${type}_fields"} = qq{Extracted to populate "${type}_fields" table};
    }

    if (my $fs = $f->{"harness_${type}_fields"}) {
        push @fields => @{$fs};
        $f->{"harness_${type}_fields"} = qq{Extracted to populate "${type}_fields" table};
    }

    if (my $p = $f->{"harness_${type}"}) {
        if (my $fs = $p->{fields}) {
            push @fields => @{$fs};
            $p->{"fields"} = qq{Extracted to populate "${type}_fields" table};
        }

        if (my $fs = $p->{"${type}_fields"}) {
            push @fields => @{$fs};
            $p->{"${type}_fields"} = qq{Extracted to populate "${type}_fields" table};
        }

        if (my $fs = $p->{"harness_${type}_fields"}) {
            push @fields => @{$fs};
            $p->{"harness_${type}_fields"} = qq{Extracted to populate "${type}_fields" table};
        }
    }

    return undef unless @fields;

    my %mixin  = $type eq 'run' ? (run_id => $self->{+RUN_ID}) : (job_try_id => $params->{try}->{job_try_id});
    my $e_uuid = $params->{e_uuid};

    for my $field (@fields) {
        my $name = $field->{name} || 'unknown';

        my $row = {
            %mixin,
            event_uuid => format_uuid_for_db($e_uuid),
            name       => $name,
            details    => $field->{details} || $name,
        };

        $row->{raw}  = $field->{raw}  if $field->{raw};
        $row->{link} = $field->{link} if $field->{link};

        $row->{data} = encode_json($field->{data}) if $field->{data};

        if ($type eq 'run') {
            push @{$self->{+RUN_FIELDS} //= []} => $row;
        }
        else {
            push @{$self->{+TRY_FIELDS} //= []} => $row;
        }
    }
}

sub _pull_facet__params {
    my $self = shift;
    my ($f, $type, $params) = @_;

    my $p = $f->{"harness_${type}"} or return undef;
    $f->{"harness_${type}"} = qq{Extracted to populate "${type}.parameters" column};

    return $p;
}

sub _pull_facet_run_fields {
    my $self = shift;
    my ($f, $params) = @_;
    return $self->_pull_facet__fields($f, 'run', $params);
}

sub _pull_facet_run_params {
    my $self = shift;
    my ($f, $params) = @_;
    return $self->_pull_facet__params($f, 'run', $params);
}

sub _pull_facet_job_try_fields {
    my $self = shift;
    my ($f, $params) = @_;
    return $self->_pull_facet__fields($f, 'job', $params);
}

sub _pull_facet_job_try_params {
    my $self = shift;
    my ($f, $params) = @_;
    return $self->_pull_facet__params($f, 'job', $params);
}

sub _pull_facet_reporting {
    my $self = shift;
    my ($f, $params) = @_;

    return if $f->{hubs}->[0]->{nested};

    my $parent = $f->{parent}       // return;
    my $assert = $f->{assert}       // return;
    my $st     = $assert->{details} // return;
    return if is_invalid_subtest_name($st);

    my $start    = $parent->{start_stamp} // return;
    my $stop     = $parent->{stop_stamp}  // return;
    my $duration = $stop - $start         // return;

    my $try = $params->{try};
    my $job = $params->{job};

    my $test_file_id = $job->{is_harness_out} ? undef : $job->{test_file_id};

    push @{$self->{+REPORTING} //= []} => {
        run_id     => $self->run_id,
        user_id    => $self->user_id,
        project_id => $self->project_id,

        job_try_id   => $try->{job_try_id},
        job_try      => $try->{job_try_ord},
        test_file_id => $test_file_id,

        subtest  => $st,
        duration => $duration,

        abort => 0,
        retry => 0,

        $assert->{pass} ? (pass => 1, fail => 0) : (fail => 1, pass => 0),
    };
}

sub _pull_facet_run_updates {
    my $self = shift;
    my ($f, $params) = @_;

    my $delta = $self->{+RUN_DELTA} //= {};

    $delta->{'=has_coverage'} = 1 if $f->{job_coverage} || $f->{run_coverage};

    $delta->{'=has_resources'} = 1 if $f->{resource_state};

    if (my $run_params = $self->_pull_facet_run_params($f, $params)) {
        $delta->{'=parameters'} = encode_json($run_params);

        my $settings = $run_params->{settings};

        if (my $r = $settings->{resource}) {
            if (my $j = $r->{slots}) {
                $delta->{'=concurrency_j'} = $j;
            }

            if (my $x = $r->{job_slots}) {
                $delta->{'=concurrency_x'} = $x;
            }
        }
        elsif (my $r2 = $settings->{runner}) { #Legacy logs
            if (my $j = $r2->{job_count}) {
                $delta->{'=concurrency_j'} = $j;
            }
        }
    }

    if (my $job_exit = $f->{harness_job_end}) {
        if ($job_exit->{fail}) {
            if ($job_exit->{retry}) {
                $delta->{'Δto_retry'} += 1;
            }
            else {
                $delta->{'Δfailed'} += 1;
            }
        }
        else {
            $delta->{'Δpassed'} += 1;
        }

        if ($params->{try}->{job_try_ord}) {
            $delta->{'Δto_retry'} -= 1;
            $delta->{'Δretried'} += 1;
        }
    }

    if (my $dur = $self->{+DURATION}) {
        unless ($params->{run}->{duration} && $dur <= $params->{run}->{duration}) {
            $delta->{'=duration'} = $dur;
            $params->{run}->{duration} = $dur;
        }
    }

    return;
}

sub _pull_facet_job_updates {
    my $self = shift;
    my ($f, $params) = @_;

    my $job_exit = $f->{harness_job_end} or return undef;

    my $delta = $params->{job}->{delta} //= {};

    if ($job_exit->{fail}) {
        $delta->{'=failed'} = 1;
    }
    else {
        $delta->{'=passed'} = 1;
    }

    return;
}

sub _pull_facet_job_try_updates {
    my $self = shift;
    my ($f, $params) = @_;

    return undef if $params->{nested};

    my $delta = $params->{try}->{delta} //= {};

    if (my $job_params = $self->_pull_facet_job_try_params($f, $params)) {
        $delta->{'=parameters'} = encode_json($job_params);
    }

    if ($params->{causes_fail}) {
        $delta->{'=fail_count'} += 1;
    }
    elsif (my $assert = $f->{assert}) {
        $delta->{'=pass_count'} += 1;
    }

    if (my $job_start = $f->{harness_job_start}) {
        $delta->{'=start'} = $self->format_stamp($job_start->{stamp});
    }

    if (my $job_launch = $f->{harness_job_launch}) {
        $delta->{'=launch'} = $self->format_stamp($job_launch->{stamp});
        $delta->{'=status'} = 'running';
    }

    if (my $job_exit = $f->{harness_job_exit}) {
        $delta->{'=exit_code'} = $job_exit->{exit} if $job_exit->{exit};

        $delta->{'=stdout'} = clean_output($job_exit->{stdout}) if $job_exit->{stdout};
        $delta->{'=stderr'} = clean_output($job_exit->{stderr}) if $job_exit->{stderr};
    }

    if (my $job_end = $f->{harness_job_end}) {
        my $try = $params->{try};
        my $job = $params->{job};

        my $report = {
            run_id     => $self->run_id,
            user_id    => $self->user_id,
            project_id => $self->project_id,

            job_try_id   => $try->{job_try_id},
            job_try      => $try->{job_try_ord},
            test_file_id => $job->{test_file_id},

            abort => $self->{+SIGNAL} ? 1 : 0,
        };

        if ($job_end->{fail}) {
            $delta->{'=fail'}  += 1;
            $delta->{'=retry'} += $job_end->{retry} ? 1 : 0;

            $report->{fail} = 1;
            $report->{pass} = 0;
            $report->{retry} = $job_end->{retry} ? 1 : 0;
        }
        else {
            $delta->{'=retry'} = 0;

            $report->{fail} = 0;
            $report->{pass} = 1;
            $report->{retry} = 0;
        }

        my $duration = 0;
        $duration = $job_end->{times}->{totals}->{total} if $job_end->{times} && $job_end->{times}->{totals} && $job_end->{times}->{totals}->{total};

        $delta->{'=ended'}    = $self->format_stamp($job_end->{stamp});
        $delta->{'=status'}   = 'complete';
        $delta->{'=duration'} = $duration if $duration;

        $params->{try}->{done} = 1;

        $report->{duration} = $duration // 0;

        push @{$self->{+REPORTING} //= []} => $report;
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

sub process_event {
    my $self = shift;
    my ($event, $f, $idx, @oops) = @_;

    croak "Too many arguments" if @oops;

    $f //= $event->{facet_data} // die "No facet data!";

    my $harness = $f->{harness} or die "No 'harness' facet!";

    my $job = $self->get_job($harness->{job_id}, queue => $f->{harness_job_queued}, job_spec => $f->{harness_job});
    my $try = $self->get_job_try($job, $harness->{job_try});

    my $sdx = 1;

    my $ok = eval {
        my @todo = ([$f, event => $event]);
        while (my $set = shift @todo) {
            my ($sf, %sp) = @$set;
            push @todo => $self->_process_event($sf, %sp, job => $job, try => $try, idx => $idx, sdx => $sdx++);
        }

        1;
    };
    my $err = $@;

    $self->flush($job, $try);

    die $err unless $ok;

    return;
}

sub validate_uuid {
    my $self = shift;
    my ($uuid) = @_;

    confess "No uuid provided" unless $uuid;
    confess "UUID '$uuid' Contains invalid characters ($1)" if $uuid =~ m/([^a-fA-F0-9\-])/;

    return 1;
}

sub _process_event {
    my $self = shift;
    my ($f, %params) = @_;

    my ($e_uuid, $formatted_stamp);
    if (my $harness = $f->{harness}) {
        $e_uuid  = $harness->{event_id} // die "No event id!";
        $formatted_stamp = $harness->{stamp} ? $self->format_stamp($harness->{stamp}) : undef;
    }
    else {
        $e_uuid = $f->{about}->{uuid} if $f->{about} && $f->{about}->{uuid};
        $e_uuid //= gen_uuid();
    }

    unless ($formatted_stamp) {
        if (my $q = $f->{harness_job_queued}) {
            $formatted_stamp = $self->format_stamp($q->{stamp});
        }

        $formatted_stamp //= $self->format_stamp($self->{+LAST_STAMP}) if $self->{+LAST_STAMP};
    }

    my $rendered = App::Yath::Renderer::Default::Composer->render_super_verbose($f);
    $rendered = undef unless $rendered && @$rendered;

    my $job = $params{job};
    my $try = $params{try};
    my $idx = $params{idx};
    my $sdx = $params{sdx};

    my $trace = $f->{trace} // {};

    die "An event cannot be its own parent" if $params{parent} && $e_uuid eq $params{parent};

    # Since we directly insert this into a query later we need to make absolutely sure it is a UUID and not any kind of injection.
    $self->validate_uuid($e_uuid);

    my $fail = causes_fail($f) ? 1 : 0;
    my $is_diag = $fail;
    $is_diag ||= 1 if $f->{errors} && @{$f->{errors}};
    $is_diag ||= 1 if $f->{assert} && !($f->{assert}->{pass} || $f->{amnesty});
    $is_diag ||= 1 if $f->{info} && first { $_->{debug} || $_->{important} } @{$f->{info}};
    $is_diag //= 0;

    my $is_time = $f->{harness_job_end} ? ($f->{harness_job_end}->{times} ? 1 : 0) : 0;
    my $is_harness = (first { substr($_, 0, 8) eq 'harness_' } keys %$f) ? 1 : 0;
    my $is_subtest = $f->{parent} ? 1 : 0;

    my $nested = $f->{hubs}->[0]->{nested} || 0;

    my $pull_params = {
        %params,
        causes_fail => $fail,
        is_diag     => $is_diag,
        e_uuid      => $e_uuid,
        is_time     => $is_time,
        is_harness  => $is_harness,
        is_subtest  => $is_subtest,
        nested      => $nested,
    };

    $self->_pull_facet_job_updates($f, $pull_params);
    $self->_pull_facet_job_try_fields($f, $pull_params);
    $self->_pull_facet_job_try_updates($f, $pull_params);
    $self->_pull_facet_job_try_coverage($f, $pull_params);
    $self->_pull_facet_run_fields($f, $pull_params);
    $self->_pull_facet_run_updates($f, $pull_params);
    $self->_pull_facet_run_coverage($f, $pull_params);
    $self->_pull_facet_resource($f, $pull_params);

    my $children  = $self->_pull_facet_children($f, $pull_params);
    my $binaries  = $self->_pull_facet_binaries($f, $pull_params);

    $self->_pull_facet_reporting($f, $pull_params) if $children;

    # Nested items are orphans unless they have a parent.
    my $orphan = $nested ? 1 : 0;
    $orphan = 0 if $params{parent};
    $orphan = 1 if $params{orphan};

    my $e;
    $e = $try->{orphan_events}->{$e_uuid} // {};

    %$e = (
        %$e,

        job_try_id => $try->{job_try_id},

        event_uuid => format_uuid_for_db($e_uuid),
        trace_uuid => $trace->{uuid} ? format_uuid_for_db($trace->{uuid}) : undef,

        stamp     => $formatted_stamp,
        event_idx => $idx,
        event_sdx => $sdx,
        nested    => $nested,

        is_subtest => $is_subtest,
        is_diag    => $is_diag,
        is_harness => $is_harness,
        is_time    => $is_time,

        causes_fail => $fail,

        has_facets => 1,

        $params{parent} ? (parent_uuid => format_uuid_for_db($params{parent})) : (),

        # Facet version wins if we have one, but we want them here if all we
        # got was an orphan.

        $binaries ? (has_binary => 1, rel_binaries => $binaries) : (has_binary => 0),

        $rendered ? (rendered => $rendered) : (),
    );

    clean($e->{facets} = $f);

    if ($orphan) {
        $e->{is_orphan} = 1;
        $try->{orphan_events}->{$e_uuid} = $e;
    }
    else {
        delete $try->{orphan_events}->{$e_uuid};
        $e->{is_orphan} = 0;

        push @{$try->{ready_events} //= []} => $e;
    }

    $try->{urgent} = 1 if $is_diag;

    return unless $children && @$children;

    return map {[$_, job => $job, try => $try, idx => $idx, parent => $e_uuid, orphan => $orphan]} @$children;
}

sub finish {
    my $self = shift;
    my (@errors) = @_;

    $self->{+DONE} = 1;

    $self->flush_all();

    my $run = $self->run;

    my $status;
    my $aborted = 0;

    if (@errors) {
        my $error = join "\n" => @errors;
        $status = {status => 'broken', error => $error};
    }
    else {
        my $stat;
        if ($self->{+SIGNAL}) {
            $stat = 'canceled';
            $aborted = 1;
        }
        else {
            $stat = 'complete';
        }

        $status = {status => $stat};
    }

    if (my $dur = $self->{+DURATION}) {
        $self->retry_on_disconnect("insert duration report row" => sub {
            my $fail = $aborted ? 0 : $run->failed ? 1 : 0;
            my $pass = ($fail || $aborted) ? 0 : 1;

            my $row = {
                run_id      => $self->{+RUN_ID},
                user_id     => $self->user_id,
                project_id  => $self->project_id,
                duration    => $dur,
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

sub DESTROY {
    return;
    my $self = shift;
    return if $self->{+DONE};
    $self->finish("Unknown issue, destructor closed out import process. \$@ was: $@", @{$self->{+ERRORS}});
}

sub flush_all {
    my $self = shift;

    $self->flush_run();
    $self->flush_coverage();
    $self->flush_reporting();
    $self->flush_try_fields();

    for my $job (values %{$self->{+JOBS}}) {

        $self->flush_job($job);

        for my $try (@{$job->{tries} // []}) {
            next unless $try;

            $self->flush_try($try);
            $self->flush_events($try);
        }
    }
}

sub flush_run {
    my $self = shift;

    if (my $delta = delete $self->{+RUN_DELTA}) {
        $self->apply_delta($self->{+RUN}, $delta);
    }

    my $run_fields = delete $self->{+RUN_FIELDS};
    my $resources  = delete $self->{+RESOURCES};

    $self->populate(RunField => $run_fields) if $run_fields && @$run_fields;
    $self->populate(Resource => $resources)  if $resources  && @$resources;

    return;
}

sub flush_coverage {
    my $self = shift;

    my $coverage = delete $self->{+COVERAGE};
    if ($coverage && @$coverage) {
        $self->populate(Coverage => $coverage);
        return 1;
    }

    return 0;
}

sub flush_reporting {
    my $self = shift;

    my $reporting = delete $self->{+REPORTING};
    if ($reporting && @$reporting) {
        $self->populate(Reporting => $reporting);
        return 1;
    }

    return 0;
}

sub flush_try_fields {
    my $self   = shift;

    my $job_fields = delete $self->{+TRY_FIELDS};
    $self->populate(JobTryField => $job_fields) if $job_fields && @$job_fields;

    return;
}

sub flush_job {
    my $self = shift;
    my ($job) = @_;

    if (my $delta = delete $job->{delta}) {
        $self->apply_delta($job->{result}, $delta);
    }
}

sub flush_try {
    my $self = shift;
    my ($try) = @_;

    my $delta = delete $try->{delta};

    if ($self->{+DONE} || $try->{done}) {
        $delta //= {};
        my $res = $try->{result};
        my $status = $delta->{'=status'} || $res->status || '';

        unless ($status eq 'complete') {
            my $status = $self->{+SIGNAL} ? 'canceled' : 'broken';
            $status = 'canceled' if $self->{+DONE} && !$try->{done};
            $status = 'complete' if $try->{job}->{is_harness_out};

            $delta->{'=status'} = $status;
        }

        my $fail = 0;
        $fail ||= $delta->{'=fail'};
        $fail ||= $res->fail;

        # Normalize the fail/pass
        $delta->{'=fail'} = $fail ? 1 : 0;
    }

    $self->apply_delta($try->{result}, $delta) if $delta;

    return;
}

sub apply_delta {
    my $self = shift;
    my ($res, $delta) = @_;

    my $update = {};

    for my $field (keys %$delta) {
        my $val = $delta->{$field};

        if ($field =~ s/^=//) {
            $update->{$field} = $val;
        }
        elsif ($field =~ s/^Δ//) {
            $update->{$field} = ($res->$field // 0) + $val;
        }
    }

    $self->retry_on_disconnect("update $res" => sub { $res->update($update) }, sub { print STDERR Dumper($update) });
}

sub flush {
    my $self = shift;
    my ($job, $try) = @_;

    my $changed = 0;

    # Always flush these, they are things we want to have up to date
    $self->flush_run();
    $self->flush_job($job);
    $self->flush_try($try);
    $self->flush_try_fields();

    my $int_flush = 0;
    my $int = $self->{+INTERVAL};
    if ($int) {
        my $last = $self->{+LAST_FLUSH};
        $int_flush = 1 if !$last || $int < time - $last;
    }

    my $bs = $self->{+BUFFER_SIZE};
    my $flushed;

    if (my $e = $try->{ready_events}) {
        my $urgent = delete $try->{urgent};
        $flushed += $self->flush_events($try, urgent => $urgent) if $try->{done} || $urgent || $int_flush || ($e && @$e >= $bs);
    }

    if (my $c = $self->{+COVERAGE}) {
        $flushed += $self->flush_coverage() if $int_flush || ($bs && @$c >= $bs);
    }

    if (my $r = $self->{+REPORTING}) {
        $flushed += $self->flush_reporting() if $int_flush || ($bs && @$r >= $bs);
    }

    $self->{+LAST_FLUSH} = time if $flushed;

    return;
}

sub flush_events {
    my $self = shift;
    my ($try, %params) = @_;

    return 0 if mode_check($self->{+MODE}, 'summary');

    my $events   = $try->{ready_events} //= [];
    my $deferred = $try->{deffered_events} //= [];

    my $urgent = $params{urgent};
    my $done   = $self->{+DONE} || $try->{done};

    if ($done) {
        my @orphans = values %{delete($try->{orphan_events}) // {}};

        if (@orphans) {
            my $msg = "Left with " . scalar(@orphans) . " orphaned events";
            push @{$self->{+ERRORS}} => "$msg.";
            warn $msg;
        }

        push @$events => @orphans;
    }

    my (@write_events, @write_bin, $parent_ids);

    if (record_all_events(mode => $self->{+MODE}, job => $try->{job}->{result}, try => $try->{result})) {
        for my $event (@$deferred, @$events) {
            $event->{facets} = encode_json($event->{facets}) if $event->{facets};
            $event->{orphan} = encode_json($event->{orphan}) if $event->{orphan};
            $event->{rendered} = encode_json($event->{rendered}) if $event->{rendered};

            $parent_ids++ if $event->{parent_uuid};

            push @write_events => $event;
            push @write_bin => @{delete($event->{rel_binaries}) // []};
        }

        @$deferred = ();
    }
    else {
        for my $event (@$events) {
            if (event_in_mode(event => $event, record_all_event => 0, mode => $self->{+MODE}, job => $try->{job}->{result}, try => $try->{result})) {
                $event->{facets} = encode_json($event->{facets}) if $event->{facets};
                $event->{orphan} = encode_json($event->{orphan}) if $event->{orphan};
                $event->{rendered} = encode_json($event->{rendered}) if $event->{rendered};

                $parent_ids++ if $event->{parent_uuid};

                push @write_events => $event;
                push @write_bin => @{delete($event->{rel_binaries}) // []};
            }
            else {
                push @$deferred => $event;
            }
        }
    }

    @$events = ();

    my $out = 0;

    if (@write_events || @write_bin) {
        $out = 1;
        $try->{normalized} = 0;

        if (@write_events) {
            @write_events = sort { $a->{event_idx} <=> $b->{event_idx} || $a->{event_sdx} <=> $b->{event_sdx} } @write_events;
            $self->populate(Event  => \@write_events);
            $self->fix_event_tree($try) if $parent_ids;
        }

        if (@write_bin) {
            $self->populate(Binary => \@write_bin);
            $self->fix_binary_events($try);
        }
    }

    if ($done && !$try->{normalized}) {
        @$deferred = (); # Not going to happen at this point
        $try->{result}->normalize_to_mode(mode => $self->{+MODE});
        $try->{normalized} = 1;
    }

    return $out;
}

sub fix_event_tree {
    my $self = shift;
    my ($try) = @_;


    my $dbh = $self->{+CONFIG}->connect;
    my $schema = $self->{+CONFIG}->schema;
    my $sth;

    if ($schema->is_postgresql || $schema->is_sqlite) {
        $sth = $dbh->prepare(<<"        EOT");
            UPDATE events
               SET parent_id = event2.event_id
              FROM events AS event2
             WHERE events.job_try_id  = ?
               AND events.job_try_id  = event2.job_try_id
               AND events.parent_id   IS NULL
               AND events.parent_uuid = event2.event_uuid
        EOT
    }
    elsif ($schema->is_mysql) {
        $sth = $dbh->prepare(<<"        EOT");
            UPDATE events event1
              JOIN events AS event2 ON event1.parent_uuid = event2.event_uuid
               SET event1.parent_id = event2.event_id
             WHERE event1.job_try_id  = ?
               AND event1.job_try_id  = event2.job_try_id
               AND event1.parent_id   IS NULL
        EOT
    }

    $sth->execute($try->{job_try_id}) or die $sth->errstr;
}

sub fix_binary_events {
    my $self = shift;
    my ($try) = @_;

    my $dbh = $self->{+CONFIG}->connect;
    my $schema = $self->{+CONFIG}->schema;
    my $sth;

    if ($schema->is_postgresql || $schema->is_sqlite) {
        $sth = $dbh->prepare(<<"        EOT");
            UPDATE binaries
               SET event_id = events.event_id
              FROM events
             WHERE events.job_try_id = ?
               AND events.event_uuid = binaries.event_uuid
        EOT
    }
    elsif ($schema->is_mysql) {
        $sth = $dbh->prepare(<<"        EOT");
            UPDATE binaries
              JOIN events ON events.event_uuid = binaries.event_uuid
               SET binaries.event_id = events.event_id
             WHERE events.job_try_id = ?
               AND events.event_uuid = binaries.event_uuid
               AND binaries.event_id IS NULL
        EOT
    }

    $sth->execute($try->{job_try_id}) or die $sth->errstr;
}

1;
__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::RunProcessor - Processes runs for database import

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

=pod

=cut POD NEEDS AUDIT

