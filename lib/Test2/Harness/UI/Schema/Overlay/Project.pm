package Test2::Harness::UI::Schema::Result::Project;
use utf8;
use strict;
use warnings;

use Statistics::Basic qw/median/;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000127';

sub last_covered_run {
    my $self = shift;
    my %params = @_;

    my $query = {
        status => 'complete',
        project_id => $self->project_id,
        has_coverage => 1,
    };

    my $attrs = {
        order_by => {'-desc' => 'run_ord'},
        rows => 1,
    };

    if ($params{user}) {
        $query->{'user.username'} = $params{user};
        push @{$attrs->{join} //= []} => 'user';
    }

    my $schema = $self->result_source->schema;

    my $run = $schema->resultset('Run')->find($query, $attrs);
    return $run;
}

sub durations {
    my $self   = shift;
    my %params = @_;

    my $median   = $params{median} || 0;
    my $short    = $params{short}  || 15;
    my $medium   = $params{medium} || 30;
    my $username = $params{user};
    my $limit    = $params{limit};

    my $schema = $self->result_source->schema;
    my $dbh = $schema->storage->dbh;

    my $query = <<"    EOT";
        SELECT test_files.filename, jobs.duration
          FROM jobs
          JOIN runs USING(run_id)
          JOIN test_files USING(test_file_id)
          JOIN users USING(user_id)
         WHERE runs.project_id = ?
           AND jobs.duration IS NOT NULL
           AND test_files.filename IS NOT NULL
    EOT
    my @vals = ($self->project_id);

    my ($user_append, @user_args) = $username ? ("users.username = ?", $username) : ();

    if ($username) {
        $query .= "AND $user_append";
        push @vals => @user_args;
    }

    if ($limit) {
        my $where = $username ? "WHERE $user_append" : "";
        my $sth   = $dbh->prepare(<<"        EOT");
            SELECT run_id
              FROM runs
              JOIN users USING(user_id)
              $where
             ORDER BY run_ord DESC
             LIMIT ?
        EOT

        $sth->execute(@user_args, $limit) or die $sth->errstr;

        my @ids = map { $_->[0] } @{$sth->fetchall_arrayref};

        $query .= "AND run_id IN (" . ('?' x scalar @ids) . ")\n";
        push @vals => (@ids);
    }

    my $sth = $dbh->prepare($query);
    $sth->execute(@vals) or die $sth->errstr;
    my $rows = $sth->fetchall_arrayref;

    my $data = {};
    for my $row (@$rows) {
        my ($file, $time) = @$row;
        push @{$data->{$file}} => $time;
    }

    for my $file (keys %$data) {
        my $set  = delete $data->{$file} or next;
        my $time = median($set);
        $data->{$file} = median($set);
    }

    if ($median) {
        my $sorted = [sort { $data->{$b} <=> $data->{$a} } keys %$data];
        $data = {lookup => $data, sorted => $sorted};
    }
    else {
        for my $file (keys %$data) {
            my $time = $data->{$file};
            my $summary;
            if    ($time < $short)  { $summary = 'SHORT' }
            elsif ($time < $medium) { $summary = 'MEDIUM' }
            else                    { $summary = 'LONG' }

            $data->{$file} = $summary;
        }
    }

    return $data;
}

1;
