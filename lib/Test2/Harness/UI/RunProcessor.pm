package Test2::Harness::UI::RunProcessor;
use strict;
use warnings;

our $VERSION = '0.000035';

use DateTime;
use Data::GUID;
use Time::HiRes qw/time/;
use List::Util qw/first/;

use Carp qw/croak confess/;

use Test2::Util::Facets2Legacy qw/causes_fail/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Formatter::Test2::Composer;

use Test2::Harness::UI::Util::ImportModes qw{
    %MODES
    record_all_events
    event_in_mode
};

use Test2::Harness::UI::Util::HashBase qw{
    <config

    <running <jobs

    signal

    <mode
    <run <run_id
    +user +user_id
    +project +project_id

    <buffer <ready_jobs <coverage

    <passed <failed <retried
    <job0_id <job_ord
};

sub format_stamp {
    my $stamp = shift;
    return undef unless $stamp;
    return DateTime->from_epoch(epoch => $stamp, time_zone => 'UTC');
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

    $self->{+PASSED} = 0;
    $self->{+FAILED} = 0;

    $self->{+JOB_ORD} = 1;
    $self->{+JOB0_ID} = gen_uuid();

    $self->{+COVERAGE} = $self->{+BUFFER} ? [] : undef;
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

    $self->{+RUN}->update({status => 'running'});

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

    my $meth = $self->{+BUFFER} ? 'new_result' : 'update_or_create';

    my %inject;
    if (my $queue = $params{queue}) {
        $inject{file} = $queue->{file};
    }

    my $result = $self->schema->resultset('Job')->$meth({
        status         => 'pending',
        job_key        => $key,
        job_id         => $job_id,
        job_try        => $job_try,
        is_harness_out => $is_harness_out,
        job_ord        => $self->{+JOB_ORD}++,
        run_id         => $self->{+RUN}->run_id,
        fail_count     => 0,
        pass_count     => 0,

        $is_harness_out ? (name => "HARNESS INTERNAL LOG") : (),

        %inject,
    });

    $job = {
        job_key    => $key,
        job_id     => $job_id,
        job_try    => $job_try,

        event_ord => 1,
        events    => {},
        result => $result,
    };

    return $self->{+JOBS}->{$job_id}->{$job_try} = $job;
}

sub process_event {
    my $self = shift;
    my ($event, $f, %params) = @_;

    $f //= $event->{facet_data} // {};

    $self->start unless $self->{+RUNNING};

    my $job = $params{job} // $self->get_job(%{$f->{harness} // {}}, queue => $f->{harness_job_queued});

    my $e = $self->_process_event($event, $f, %params, job => $job);
    clean($e);

    if ($self->{+BUFFER}) {
        $job->{events}->{$e->{event_id}} = $e;
        $self->flush_ready_jobs();
    }
    else {
        $self->schema->resultset('Event')->update_or_create($e);
    }
}

sub finish {
    my $self = shift;
    my (@errors) = @_;

    $self->flush_coverage();
    $self->flush_all_jobs();

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

    $run->update($status);

    $run->normalize_to_mode() unless $self->{+BUFFER} || $run->mode eq 'complete';

    return $status;
}

sub flush_coverage {
    my $self = shift;
    my $coverage = $self->{+COVERAGE} or return;
    return unless @$coverage;

    my $schema = $self->schema;
    $schema->txn_begin;
    my $ok = eval {
        local $ENV{DBIC_DT_SEARCH_OK} = 1;
        $schema->resultset('Coverage')->populate($coverage);
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

sub flush_ready_jobs {
    my $self = shift;

    my $jobs = delete $self->{+READY_JOBS};
    return unless $jobs && @$jobs;

    my (@events);

    my $mode = $self->{+MODE};

    for my $job (@$jobs) {
        my $res  = $job->{result};
        $res->status($self->{+SIGNAL} ? 'canceled' : 'broken') unless $res->status eq 'complete';

        # Normalize the fail/pass
        my $fail = $res->fail ? 1 : 0;
        $res->fail($fail);

        my $is_harness_out = $res->is_harness_out;

        my $events = delete $job->{events} // [];
        next if $mode <= $MODES{summary};

        my %record_check_params = (
            job            => $res,
            run            => $self->{+RUN},
            mode           => $mode,
            fail           => $fail,
            is_harness_out => $is_harness_out,
        );

        my $record_all_events = record_all_events(%record_check_params);
        $record_check_params{record_all_events} = $record_all_events;

        my @unsorted = values %$events;

        @unsorted = grep { event_in_mode(event => $_, %record_check_params) } @unsorted
            unless $record_all_events;

        push @events => sort { $a->{event_ord} <=> $b->{event_ord} } @unsorted;
    }

    my $schema = $self->{+CONFIG}->schema;
    $schema->txn_begin;
    my $ok = eval {
        my $start = time;
        local $ENV{DBIC_DT_SEARCH_OK} = 1;
        $_->{result}->insert_or_update() for @$jobs;
        $schema->resultset('Event')->populate(\@events) if @events;
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

    my $all = delete $self->{+JOBS};
    for my $jobs (values %$all) {
        push @{$self->{+READY_JOBS}} => values %$jobs;
    }

    $self->flush_ready_jobs();
}

sub _process_event {
    my $self = shift;
    my ($event, $f, %params) = @_;
    my $job = $params{job};

    clean($f);
    my $fjson = encode_json($f);

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

    my $e = {
        event_id   => $e_id,
        nested     => $nested,
        is_diag    => $is_diag,
        is_harness => $is_harness,
        is_time    => $is_time,
        trace_id   => $trace->{uuid},
        job_key    => $job->{job_key},
        event_ord  => $job->{event_ord}++,
        stamp      => format_stamp($harness->{stamp} || $event->{stamp} || $params{stamp} || time),
    };

    my $orphan = $nested ? 1 : 0;
    if (my $p = $params{parent_id}) {
        $e->{parent_id} ||= $p;
        $orphan = 0;
    }

    if ($orphan) {
        $e->{orphan}      = $fjson;
        $e->{orphan_line} = $params{line} if $params{line};
    }
    else {
        # Handle coverage
        if (my $coverage = $f->{coverage}) {
            $self->add_coverage($job, $coverage);
        }

        $e->{facets}      = $fjson;
        $e->{facets_line} = $params{line} if $params{line};

        if ($f->{parent} && $f->{parent}->{children}) {
            $self->process_event({}, $_, job => $job, parent_id => $e_id, line => $params{line}) for @{$f->{parent}->{children}};
            $f->{parent}->{children} = "Removed, used to populate events table";
        }

        unless ($nested) {
            my $res = $job->{result};
            $res->fail_count($res->fail_count + 1) if $fail;
            $res->pass_count($res->pass_count + 1) if $f->{assert} && !$fail;

            $self->update_other($job, $f) if $e->{is_harness};

            $res->update() unless $self->{+BUFFER};
        }
    }

    return $e;
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

sub add_coverage {
    my $self = shift;
    my ($job, $coverage) = @_;

    my @rows = map { +{file => $_, job_key => $job->{job_key}} } @{$coverage->{files}};

    if ($self->{+BUFFER}) {
        push @{$self->{+COVERAGE}} => @rows;
    }
    else {
        local $ENV{DBIC_DT_SEARCH_OK} = 1;
        $self->schema->resultset('Coverage')->populate(\@rows);
    }
}

sub merge_fields {
    my $self = shift;
    my ($existing, $new) = @_;

    $existing = decode_json($existing) if $existing && !ref($existing);
    $new      = decode_json($new)      if $new      && !ref($new);

    my @merged;
    push @merged => @$existing if $existing && @$existing;
    push @merged => @$new if $new && @$new;
    return encode_json(\@merged);
}

sub update_other {
    my $self = shift;
    my ($job, $f) = @_;

    if (my $run_data = $f->{harness_run}) {
        my $run = $self->{+RUN};

        clean($run_data);
        $run->update({parameters => $run_data});

        if (my $fields = $run_data->{harness_run_fields} // $run_data->{fields}) {
            my $run_id = $run->run_id;
            my @new = map { { %{$_}, run_id => $run_id } } @$fields;
            $self->{+RUN}->update({fields => $self->merge_fields($run->fields, \@new)});
        }
    }

    my $job_result = $job->{result};
    my %cols = $job_result->get_columns;

    # Handle job events
    if (my $job_data = $f->{harness_job}) {
        $cols{file} ||= $job_data->{file};
        $cols{name} ||= $job_data->{job_name};
        clean($job_data);
        $cols{parameters} = encode_json($job_data);
        $f->{harness_job}  = "Removed, see job with job_key $cols{job_key}";
    }
    if (my $job_exit = $f->{harness_job_exit}) {
        $cols{file} ||= $job_exit->{file};
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
        $cols{file} = $job_start->{rel_file} if $job_start->{rel_file};
        $cols{file} ||= $job_start->{file};
        $cols{start} = format_stamp($job_start->{stamp});
    }
    if (my $job_launch = $f->{harness_job_launch}) {
        $cols{status} = 'running';

        $cols{file} ||= $job_launch->{file};
        $cols{launch} = format_stamp($job_launch->{stamp});
    }
    if (my $job_end = $f->{harness_job_end}) {
        $cols{status} = $self->{+SIGNAL} ? 'canceled' : 'complete';

        $cols{file} ||= $job_end->{file};
        $cols{fail}  = $job_end->{fail} ? 1 : 0;
        $cols{ended} = format_stamp($job_end->{stamp});

        $cols{fail} ? $self->{+FAILED}++ : $self->{+PASSED}++;

        # All done
        delete $self->{+JOBS}->{$cols{job_id}}->{$cols{job_try}};
        push @{$self->{+READY_JOBS}} => $job if $self->{+BUFFER};

        if ($job_end->{rel_file} && $job_end->{times} && $job_end->{times}->{totals} && $job_end->{times}->{totals}->{total}) {
            $cols{file} = $job_end->{rel_file} if $job_end->{rel_file};
            $cols{duration} = $job_end->{times}->{totals}->{total};
        }
    }
    if (my $job_fields = $f->{harness_job_fields}) {
        my @new = map { {%{$_}} } @$job_fields;
        $cols{fields} = $self->merge_fields($cols{fields}, \@new)
    }

    $job_result->set_columns(\%cols);

    return;
}

1;

__END__

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
