package Test2::Harness::UI::Schema::Result::Project;
use utf8;
use strict;
use warnings;

use Statistics::Basic qw/median/;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000120';

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

    my $median = $params{median} || 0;
    my $short  = $params{short}  || 15;
    my $medium = $params{medium} || 30;

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

    if (my $username = $params{user}) {
        $query .= "AND users.username = ?";
        push @vals => $username;
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
