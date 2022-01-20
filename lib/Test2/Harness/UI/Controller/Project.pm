package Test2::Harness::UI::Controller::Project;
use strict;
use warnings;

our $VERSION = '0.000105';

use Time::Elapsed qw/elapsed/;
use List::Util qw/sum/;
use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Project Stats' }

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
    coverage       => 1,
    uncovered      => 1,
    file_failures  => 1,
    sub_failures   => 1,
    file_durations => 1,
    sub_durations  => 1,
);

sub build_stat {
    my $self = shift;
    my ($project, $stat) = @_;

    return unless $stat;

    my $type = $stat->{type};

    return {%$stat, error => "Invalid type '$type'"} unless $VALID_TYPES{$type};

    eval {
        my $meth = "_build_stat_$type";
        $self->$meth($project => $stat);
        1;
    } or return {%$stat, error => $@};

    return $stat;
}

sub _build_stat_file_durations {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};

    my $schema = $self->{+CONFIG}->schema;

    my $fields_rs = $schema->resultset('JobField')->search(
        { 'me.name'        => 'time_total',
          'run.status'     => 'complete',
          'run.project_id' => $project->project_id,
        },
        { join     => { job_key => 'run' },
          order_by => {'-DESC'  => 'run.added'},
          prefetch => 'job_key' },
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

my %BAD_ST_NAME = (
    '__ANON__'            => 1,
    'unnamed'             => 1,
    'unnamed subtest'     => 1,
    'unnamed summary'     => 1,
    '<UNNAMED ASSERTION>' => 1,
);

sub _build_stat_sub_durations {
    my $self = shift;
    my ($project, $stat) = @_;

    my $n = $stat->{n};

    my $schema = $self->{+CONFIG}->schema;

    my $events_rs = $schema->resultset('Event')->search(
        { 'me.is_subtest'  => 1,
          'run.status'     => 'complete',
          'run.project_id' => $project->project_id,
        },
        { join     => { job_key => 'run' },
          order_by => {'-DESC'  => 'run.added'},
          prefetch => 'job_key' },
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

    my $events_rs = $schema->resultset('Event')->search(
        { 'me.is_subtest'  => 1,
          'run.status'     => 'complete',
          'run.project_id' => $project->project_id,
        },
        { join     => { job_key => 'run' },
          order_by => {'-DESC'  => 'run.added'},
          prefetch => 'job_key' },
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

    my $jobs_rs = $schema->resultset('Job')->search(
        { 'run.status'     => 'complete',
          'run.project_id' => $project->project_id,
        },
        { join     => 'run',
          order_by => {'-DESC'  => 'run.added'}},
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

    my $field = $schema->resultset('RunField')->search(
        { 'me.name'        => 'coverage',
          'run.project_id' => $project->project_id },
        { join             => 'run',
          order_by         => {'-DESC' => 'run.added'},
          rows             => 1 } ,
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

    my @items = reverse $schema->resultset('RunField')->search(
        { 'me.name'        => 'coverage',
          'run.project_id' => $project->project_id },
        { join             => 'run',
          order_by         => {'-DESC' => 'run.added'},
                $n ? (rows => $n) : (),
        } ,
    )->all;

    my $labels = [];
    my $subs   = [];
    my $files  = [];
    for my $item (@items) {
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
                point => { radius => 1 },
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
