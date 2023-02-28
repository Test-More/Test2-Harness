package Test2::Harness::UI::Controller::Project;
use strict;
use warnings;

our $VERSION = '0.000135';

use Time::Elapsed qw/elapsed/;
use List::Util qw/sum/;
use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir format_duration parse_duration is_invalid_subtest_name/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub display_duration {
    my $dur = shift // return "N/A";
    return elapsed($dur) || sprintf('%1.1f seconds', $dur);
}

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
    $res->add_css('view.css');
    $res->add_css('project.css');
    $res->add_js('runtable.js');
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
    run_list           => 1,
    coverage           => 1,
    uncovered          => 1,
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

sub parse_date {
    my $raw = shift;

    my ($m, $d, $y) = split '/', $raw;
    return sprintf("%04d-%02d-%02d", $y, $m, $d);
}

sub get_add_query {
    my $self = shift;
    my ($project, $stat, %overrides) = @_;

    my $n     = $overrides{n}          // $stat->{n};
    my $users = $overrides{users}      // $stat->{users};
    my $start = $overrides{start_date} // $stat->{start_date};
    my $end   = $overrides{end_date}   // $stat->{end_date};

    my $range = $start && $end;

    return ('') unless $n || @$users || $range;

    return ("AND run_ord > (SELECT MAX(run_ord) - ? FROM runs)\n", $n)
        unless @$users || $range;

    my @add_vals;

    my $user_query = 'user_id in (' . join(',' => map { '?' } @$users) . ')';
    push @add_vals => @$users;

    return ("AND $user_query\n", @add_vals) unless $n || $range;

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    if ($range) {
        my $query = <<"        EOT";
            SELECT min(run_ord) AS min, max(run_ord) AS max
              FROM runs
             WHERE project_id = ?
               AND added >= ?
               AND added <= ?
        EOT

        $start = parse_date($start);
        $end   = parse_date($end);

        my $sth = $dbh->prepare($query);
        $sth->execute($project->project_id, $start, $end) or die $sth->errstr;

        my $ords = $sth->fetchrow_hashref;

        my $ord_query = "run_ord >= ? AND run_ord <= ?";
        push @add_vals => ($ords->{min}, $ords->{max});
        return ("AND $user_query AND $ord_query", @add_vals) if @$users;
        return ("AND $ord_query", @add_vals);
    }

    my $query = <<"    EOT";
        SELECT run_ord, run_id
          FROM reporting
         WHERE project_id = ?
           AND $user_query
      GROUP BY run_ord, run_id
      ORDER BY run_ord DESC
         LIMIT ?
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @add_vals, $n) or die $sth->errstr;

    my @ids = map { $_->[1] } @{$sth->fetchall_arrayref};
    return ('') unless @ids;

    return ("AND run_id IN (" . join(',' => map { '?' } @ids)  . ")\n", @ids);
}


sub _build_stat_run_list {
    my $self = shift;
    my ($project, $stat) = @_;

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my ($add_query, @add_vals) = $self->get_add_query($project, $stat);

    my $query = <<"    EOT";
        SELECT run_id
          FROM reporting
         WHERE project_id = ?
           $add_query
      ORDER BY run_id DESC
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @add_vals) or die $sth->errstr;

    my @ids = map { $_->[0] } @{$sth->fetchall_arrayref};

    my @items = map { $_->TO_JSON } $schema->resultset('Run')->search({run_id => {'-in' => \@ids}}, {order_by => {'-DESC' => 'run_ord'}})->all;

    $stat->{runs} = \@items;
}

sub _build_stat_expensive_files {
    my $self = shift;
    my ($project, $stat) = @_;

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my ($add_query, @add_vals) = $self->get_add_query($project, $stat);

    my $query = <<"    EOT";
        SELECT test_files.filename      AS filename,
               SUM(duration)            AS total_duration,
               AVG(duration)            AS average_duration,
               COUNT(DISTINCT(run_ord)) AS runs,
               COUNT(duration)          AS tries,
               COUNT(DISTINCT(user_id)) AS users,
               SUM(pass)                AS pass,
               SUM(fail)                AS fail,
               SUM(retry)               AS retry,
               SUM(abort)               AS abort
          FROM reporting
     LEFT JOIN test_files USING(test_file_id)
         WHERE project_id    = ?
           AND subtest      IS     NULL
           AND test_file_id IS NOT NULL
           $add_query
      GROUP BY filename
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @add_vals) or die $sth->errstr;

    my @rows;
    for my $row (sort { $b->[1] <=> $a->[1] } @{$sth->fetchall_arrayref}) {
        splice(
            @$row, 6, 0,
            int($row->[6] / $row->[4] * 100) . '%',
            int($row->[7] / $row->[4] * 100) . '%',
        );
        $row->[1] = {formatted => display_duration($row->[1]), raw => $row->[1]};
        $row->[2] = {formatted => display_duration($row->[2]), raw => $row->[2]};
        unshift @$row => {};
        push @rows => $row;
    }

    $stat->{table} = {
        class => 'expense',
        sortable => 1,
        header => ['Test File', 'Total Time', 'Average Time', 'Runs', 'Jobs', 'Users', 'Pass Rate', 'Failure Rate', 'Passes', 'Fails', 'Retries', 'Aborts'],
        rows => \@rows,
    };
}

sub _build_stat_expensive_subtests {
    my $self = shift;
    my ($project, $stat) = @_;

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my ($add_query, @add_vals) = $self->get_add_query($project, $stat);

    my $query = <<"    EOT";
        SELECT test_files.filename      AS filename,
               subtest                  AS subtest,
               SUM(duration)            AS total_duration,
               AVG(duration)            AS average_duration,
               COUNT(DISTINCT(run_ord)) AS runs,
               COUNT(duration)          AS tries,
               COUNT(DISTINCT(user_id)) AS users,
               SUM(pass)                AS pass,
               SUM(fail)                AS fail,
               SUM(abort)               AS abort
          FROM reporting
     LEFT JOIN test_files USING(test_file_id)
         WHERE project_id    = ?
           AND subtest      IS NOT NULL
           AND test_file_id IS NOT NULL
           $add_query
      GROUP BY filename, subtest
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @add_vals) or die $sth->errstr;

    my @rows;
    for my $row (sort { $b->[2] <=> $a->[2] } @{$sth->fetchall_arrayref}) {
        splice(
            @$row, 7, 0,
            int($row->[7] / $row->[5] * 100) . '%',
            int($row->[8] / $row->[5] * 100) . '%',
        );
        $row->[2] = {formatted => display_duration($row->[2]), raw => $row->[2]};
        $row->[3] = {formatted => display_duration($row->[3]), raw => $row->[3]};
        unshift @$row => {};
        push @rows => $row;
    }

    $stat->{table} = {
        class => 'expense',
        sortable => 1,
        header => ['Test File', 'Subtest', 'Total Time', 'Average Time', 'Runs', 'Jobs', 'Users', 'Pass Rate', 'Failure Rate', 'Passes', 'Fails', 'Aborts'],
        rows => \@rows,
    };
}

sub _build_stat_expensive_users {
    my $self = shift;
    my ($project, $stat) = @_;

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my ($add_query, @add_vals) = $self->get_add_query($project, $stat);

    my $query = <<"    EOT";
        SELECT users.username  AS username,
               SUM(duration)   AS total_duration,
               AVG(duration)   AS average_duration,
               COUNT(duration) AS runs,
               SUM(pass)       AS pass,
               SUM(fail)       AS fail,
               SUM(abort)      AS abort
          FROM reporting
     LEFT JOIN users USING(user_id)
         WHERE project_id = ?
           AND job_key    IS NULL
           AND subtest    IS NULL
           $add_query
      GROUP BY username
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @add_vals) or die $sth->errstr;

    my @rows;
    for my $row (sort { $b->[1] <=> $a->[1] } @{$sth->fetchall_arrayref}) {
        splice(
            @$row, 4, 0,
            int($row->[4] / $row->[3] * 100) . '%',
            int($row->[5] / $row->[3] * 100) . '%',
        );
        $row->[1] = {formatted => display_duration($row->[1]), raw => $row->[1]};
        $row->[2] = {formatted => display_duration($row->[2]), raw => $row->[2]};
        unshift @$row => {};
        push @rows => $row;
    }

    $stat->{table} = {
        class => 'expense',
        sortable => 1,
        header => ['User', 'Total Time', 'Average Time', 'Runs', 'Pass Rate', 'Fail Rate', 'Passes', 'Fails', 'Aborts'],
        rows => \@rows,
    };
}

sub _build_stat_user_summary {
    my $self = shift;
    my ($project, $stat) = @_;

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my ($add_query, @add_vals) = $self->get_add_query($project, $stat);

    my $query = <<"    EOT";
        SELECT SUM(duration)            AS total_duration,
               AVG(duration)            AS average_duration,
               COUNT(DISTINCT(run_ord)) AS runs,
               COUNT(DISTINCT(user_id)) AS users,
               SUM(pass)                AS pass,
               SUM(fail)                AS fail,
               SUM(retry)               AS retry,
               SUM(abort)               AS abort,
               CASE WHEN test_file_id IS NULL THEN FALSE ELSE TRUE END AS has_file,
               CASE WHEN subtest      IS NULL THEN FALSE ELSE TRUE END AS has_subtest,
               COUNT(subtest) AS total_subtests,
               COUNT(test_file_id) AS total_test_files,
               COUNT(DISTINCT(subtest)) AS unique_subtests,
               COUNT(DISTINCT(test_file_id)) AS unique_test_files
          FROM reporting
         WHERE project_id    = ?
           $add_query
      GROUP BY has_file, has_subtest
      ORDER BY has_File, has_subtest
    EOT

    my $sth = $dbh->prepare($query);
    $sth->execute($project->project_id, @add_vals) or die $sth->errstr;

    my $runs = $sth->fetchrow_hashref;

    return $stat->{text} = "No run data." unless $runs->{runs};

    my $jobs = $sth->fetchrow_hashref;
    my $subs = $sth->fetchrow_hashref;

    $stat->{pair_sets} = [];

    push @{$stat->{pair_sets}} => [
        ['User Summary'],
        ["Total unique users"    => $runs->{users} // 0],
        ["Average time per user" => display_duration(($runs->{total_duration} // 0) / $runs->{users})],
        ["Average runs per user" => $runs->{runs} / $runs->{users}],
    ] if $runs->{runs} && $runs->{users};

    push @{$stat->{pair_sets}} => [
        ['Run Summary'],
        ["Total time spent running tests" => display_duration($runs->{total_duration}   // 0)],
        ["Average time per test run"      => display_duration($runs->{average_duration} // 0)],
        ["Total runs"            => $runs->{runs}  // 0],
        ["Total incomplete runs" => $runs->{abort} // 0],
        ["Total passed runs"     => $runs->{pass}  // 0],
        ["Total failed runs"     => $runs->{fail}  // 0],
    ] if $runs->{runs};

    push @{$stat->{pair_sets}} => [
        ['Job Summary'],
        ["Average time per job"    => display_duration($runs->{total_duration} / $jobs->{total_test_files})],
        ["Total unique test files" => $jobs->{unique_test_files} // 0],
        ["Total jobs executed"     => $jobs->{total_test_files}  // 0],
        ["Total passed files"      => $jobs->{pass}              // 0],
        ["Total failed files"      => $jobs->{fail}              // 0],
        ["Total retried files"     => $jobs->{retry}             // 0],
    ] if $jobs->{total_test_files};

    push @{$stat->{pair_sets}} => [
        ['Subtest Summary'],
        ["Average time per subtest" => display_duration($subs->{total_duration} / $subs->{total_subtests})],
        ["Total unique subtests"    => $subs->{unique_subtests} // 0],
        ["Total subtests executed"  => $subs->{total_subtests}  // 0],
        ["Total passed subtests"    => $subs->{pass}            // 0],
        ["Total failed sustests"    => $subs->{fail}            // 0],
        ["Total retried subtests"   => $subs->{retry}           // 0],
    ] if $subs->{total_subtests};
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
