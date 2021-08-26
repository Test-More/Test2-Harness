package Test2::Harness::UI::Schema::Result::Project;
use utf8;
use strict;
use warnings;

use Statistics::Basic qw/median/;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000083';

sub coverage {
    my $self = shift;
    my %params = @_;

    my $query = {
        name => 'coverage',
        data => {'IS NOT' => undef},
        'run.project_id' => $self->project_id,
    };
    my $attrs = {
        join => 'run',
        order_by => {'-desc' => 'run.run_ord'},
        rows => 1,
    };

    my $schema = $self->result_source->schema;
    if (my $publisher = $params{user}) {
        my $user = $schema->resultset('User')->find({username => $publisher}) or confess "Invalid publisher '$publisher'.\n";
        $query->{'run.user_id'} = $user->user_id;
    }

    my $field = $schema->resultset('RunField')->find($query, $attrs)
        or return;

    return $field;
}

sub durations {
    my $self   = shift;
    my %params = @_;

    my $median = $params{median} || 0;
    my $short  = $params{short}  || 15;
    my $medium = $params{medium} || 30;

    my $schema = $self->result_source->schema;
    my $dbh = $schema->storage->dbh;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT jobs.file, jobs.duration
          FROM jobs
          JOIN runs USING(run_id)
         WHERE runs.project_id = ?
           AND jobs.duration IS NOT NULL
           AND jobs.file IS NOT NULL
    EOT

    $sth->execute($self->project_id) or die $sth->errstr;
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
