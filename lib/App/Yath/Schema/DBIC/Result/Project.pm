package App::Yath::Schema::DBIC::Result::Project;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql/;

use Statistics::Basic qw/median/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("projects");

__PACKAGE__->add_columns(
    "project_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "projects_project_id_seq") : ()),
    },
    "owner" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "name" => {
        data_type   => is_postgresql() ? "citext" : "varchar",
        is_nullable => 0,
        (is_postgresql() ? () : (size => 128)),
    },
);

__PACKAGE__->set_primary_key("project_id");
__PACKAGE__->add_unique_constraint("name_unique", ["name"]);

__PACKAGE__->belongs_to(
    "owner" => "App::Yath::Schema::DBIC::Result::User",
    { user_id => "owner" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "SET NULL",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->has_many(
    "permissions" => "App::Yath::Schema::DBIC::Result::Permission",
    { "foreign.project_id" => "self.project_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "reports" => "App::Yath::Schema::DBIC::Result::Reporting",
    { "foreign.project_id" => "self.project_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "runs" => "App::Yath::Schema::DBIC::Result::Run",
    { "foreign.project_id" => "self.project_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

sub last_covered_run {
    my $self = shift;
    my %params = @_;

    my $query = {
        status => 'complete',
        project_id => $self->project_id,
        has_coverage => 1,
    };

    my $attrs = {
        order_by => {'-desc' => 'run_id'},
        rows => 1,
    };

    my $schema = $self->result_source->schema;

    if (my $username = $params{user}) {
        my $user = $schema->resultset('User')->find({username => $username}) or die "Invalid user: $username";
        $query->{'user_id'} = $user->user_id;
    }

    my $run = $schema->resultset('Run')->find($query, $attrs);
    return $run;
}

sub durations {
    my $self   = shift;
    my %params = @_;

    my $username = $params{user};
    my $limit    = $params{limit};

    my $schema = $self->result_source->schema;
    my $dbh = $schema->storage->dbh;

    my $query = <<"    EOT";
        SELECT test_files.filename, job_tries.duration
          FROM job_tries
          JOIN jobs USING(job_id)
          JOIN runs USING(run_id)
          JOIN test_files USING(test_file_id)
          JOIN users USING(user_id)
         WHERE runs.project_id = ?
           AND job_tries.duration IS NOT NULL
           AND test_files.filename IS NOT NULL
    EOT
    my @vals = ($self->project_id);

    my ($user_append, @user_args) = $username ? ("users.username = ?", $username) : ();

    if ($username) {
        $query .= "AND $user_append\n";
        push @vals => @user_args;
    }

    if ($limit) {
        my $where = $username ? "WHERE $user_append" : "";
        my $sth   = $dbh->prepare(<<"        EOT");
            SELECT run_id
              FROM runs
              JOIN users USING(user_id)
              $where
             ORDER BY run_id DESC
             LIMIT ?
        EOT

        $sth->execute(@user_args, $limit) or die $sth->errstr;

        my @ids = map { $_->[0] } @{$sth->fetchall_arrayref};

        if (@ids) {
            $query .= "AND run_id IN (" . join(',', map { '?' } @ids) . ")";
            push @vals => (@ids);
        }
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

    my $sorted = [sort { $data->{$b} <=> $data->{$a} } keys %$data];
    $data = {lookup => $data, sorted => $sorted};

    return $data;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Project - DBIC Result class for the Project table.

=cut
