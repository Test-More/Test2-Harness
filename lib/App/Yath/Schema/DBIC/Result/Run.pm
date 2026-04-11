package App::Yath::Schema::DBIC::Result::Run;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_mysql is_percona format_uuid_for_app format_uuid_for_db/;

use Carp qw/confess/;

use App::Yath::Schema::DateTimeFormat qw/DTF/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("runs");

__PACKAGE__->add_columns(
    "run_uuid" => do {
        if (is_percona()) {
            +{
                data_type   => "binary",
                is_nullable => 0,
                size        => 16,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "uuid",
                is_nullable => 0,
                size        => 16,
            };
        }
        else {
            +{
                data_type   => "uuid",
                is_nullable => 0,
            };
        }
    },
    "run_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "runs_run_id_seq") : ()),
    },
    "user_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "project_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "log_file_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "passed" => {
        data_type   => "integer",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "failed" => {
        data_type   => "integer",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "to_retry" => {
        data_type   => "integer",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "retried" => {
        data_type   => "integer",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "concurrency_j" => {
        data_type   => "integer",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "concurrency_x" => {
        data_type   => "integer",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "added" => do {
        if (is_sqlite()) {
            +{
                data_type     => "datetime",
                default_value => \"now",
                is_nullable   => 0,
                size          => 6,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "timestamp with time zone",
                default_value => \"current_timestamp",
                is_nullable   => 0,
                original      => { default_value => \"now()" },
            };
        }
        elsif (is_percona()) {
            +{
                data_type                 => "datetime",
                datetime_undef_if_invalid => 1,
                default_value             => "CURRENT_TIMESTAMP",
                is_nullable               => 0,
            };
        }
        else {
            +{
                data_type                 => "timestamp",
                datetime_undef_if_invalid => 1,
                default_value             => "current_timestamp(6)",
                is_nullable               => 0,
            };
        }
    },
    "status" => do {
        if (is_sqlite()) {
            +{
                data_type     => "text",
                default_value => "pending",
                is_nullable   => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "enum",
                default_value => "pending",
                is_nullable   => 0,
                extra         => {
                    custom_type_name => "queue_stat",
                    list             => ["pending", "running", "complete", "broken", "canceled"],
                },
            };
        }
        else {
            +{
                data_type     => "enum",
                default_value => "pending",
                is_nullable   => 0,
                extra         => { list => ["pending", "running", "complete", "broken", "canceled"] },
            };
        }
    },
    "mode" => do {
        if (is_sqlite()) {
            +{
                data_type     => "text",
                default_value => "qvfd",
                is_nullable   => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "enum",
                default_value => "qvfd",
                is_nullable   => 0,
                extra         => {
                    custom_type_name => "run_modes",
                    list             => ["summary", "qvfds", "qvfd", "qvf", "complete"],
                },
            };
        }
        else {
            +{
                data_type     => "enum",
                default_value => "qvfd",
                is_nullable   => 0,
                extra         => { list => ["qvfds", "qvfd", "qvf", "summary", "complete"] },
            };
        }
    },
    "canon" => do {
        if (is_sqlite()) {
            +{
                data_type   => "bool",
                is_nullable => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "boolean",
                is_nullable => 0,
            };
        }
        else {
            +{
                data_type   => "tinyint",
                is_nullable => 0,
            };
        }
    },
    "pinned" => do {
        if (is_sqlite()) {
            +{
                data_type     => "bool",
                default_value => \"FALSE",
                is_nullable   => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "boolean",
                default_value => \"false",
                is_nullable   => 0,
            };
        }
        else {
            +{
                data_type     => "tinyint",
                default_value => 0,
                is_nullable   => 0,
            };
        }
    },
    "has_coverage" => do {
        if (is_sqlite()) {
            +{
                data_type     => "bool",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "boolean",
                is_nullable => 1,
            };
        }
        else {
            +{
                data_type   => "tinyint",
                is_nullable => 1,
            };
        }
    },
    "has_resources" => do {
        if (is_sqlite()) {
            +{
                data_type     => "bool",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "boolean",
                is_nullable => 1,
            };
        }
        else {
            +{
                data_type   => "tinyint",
                is_nullable => 1,
            };
        }
    },
    "parameters" => do {
        if (is_sqlite()) {
            +{
                data_type     => "json",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "jsonb",
                is_nullable => 1,
            };
        }
        elsif (is_percona()) {
            +{
                data_type   => "json",
                is_nullable => 1,
            };
        }
        else {
            +{
                data_type   => "longtext",
                is_nullable => 1,
            };
        }
    },
    "worker_id" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "error" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "duration" => {
        data_type   => is_mysql() ? "decimal" : "numeric",
        is_nullable => 1,
        size        => [14, 4],
        (is_mysql() ? () : (default_value => \"null")),
    },
);

__PACKAGE__->set_primary_key("run_id");
__PACKAGE__->add_unique_constraint("run_uuid_unique", ["run_uuid"]);

__PACKAGE__->has_many(
    "coverage" => "App::Yath::Schema::DBIC::Result::Coverage",
    { "foreign.run_id" => "self.run_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "jobs" => "App::Yath::Schema::DBIC::Result::Job",
    { "foreign.run_id" => "self.run_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->belongs_to(
    "log_file" => "App::Yath::Schema::DBIC::Result::LogFile",
    { log_file_id => "log_file_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "SET NULL",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->belongs_to(
    "project" => "App::Yath::Schema::DBIC::Result::Project",
    { project_id => "project_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->has_many(
    "reports" => "App::Yath::Schema::DBIC::Result::Reporting",
    { "foreign.run_id" => "self.run_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "resources" => "App::Yath::Schema::DBIC::Result::Resource",
    { "foreign.run_id" => "self.run_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "run_fields" => "App::Yath::Schema::DBIC::Result::RunField",
    { "foreign.run_id" => "self.run_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "sweeps" => "App::Yath::Schema::DBIC::Result::Sweep",
    { "foreign.run_id" => "self.run_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->belongs_to(
    "user" => "App::Yath::Schema::DBIC::Result::User",
    { user_id => "user_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

# For joining
__PACKAGE__->belongs_to(
    "user_join" => "App::Yath::Schema::DBIC::Result::User",
    { user_id => "user_id" },
    { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

if (is_percona()) {
    __PACKAGE__->inflate_column(
        'run_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
}

my %COMPLETE_STATUS = (complete => 1, failed => 1, canceled => 1, broken => 1);
sub complete { return $COMPLETE_STATUS{$_[0]->status} // 0 }

sub sig {
    my $self = shift;

    my $parameters = $self->parameters;

    return join ";" => (
        (map {$self->$_ // ''} qw/status pinned passed failed retried concurrency_j concurrency_x/),
        $parameters ? length($parameters) : (''),
        (scalar $self->run_fields->count),
    );
}

sub short_run_fields {
    my $self = shift;

    return $self->run_fields->search(undef, {
        remove_columns => ['data', 'parameters'],
        '+select' => ['data IS NOT NULL AS has_data'],
        '+as' => ['has_data'],
    })->all;
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;

    $cols{user}    //= $self->user->username;
    $cols{project} //= $self->project->name;

    $cols{fields} = [];
    for my $rf ($cols{prefetched_fields} ? $self->run_fields : $self->short_run_fields) {
        my $fields = {$rf->get_all_fields};

        my $has_data = delete $fields->{data};
        $fields->{has_data} //= $has_data ? \'1' : \'0';

        push @{$cols{fields}} => $fields;
    }

    my $dt = DTF()->parse_datetime($cols{added});

    $cols{added} = $dt->strftime("%Y-%m-%d %I:%M%P");

    return \%cols;
}

sub normalize_to_mode {
    my $self = shift;
    my %params = @_;

    my $mode = $params{mode};

    if ($mode) {
        $self->update({mode => $mode});
    }
    else {
        $mode = $self->mode;
    }

    $_->normalize_to_mode(mode => $mode) for $self->jobs->all;
}

sub expanded_coverage {
    my $self = shift;
    my ($query) = @_;

    $self->coverage->search(
        $query,
        {
            order_by   => [qw/me.test_file_id me.source_file_id me.source_sub_id/],
            join       => [qw/test_file source_file source_sub coverage_manager/],
            '+columns' => {
                test_file   => 'test_file.filename',
                source_file => 'source_file.filename',
                source_sub  => 'source_sub.subname',
                manager     => 'coverage_manager.package',
            },
        },
    );
}

sub coverage_data {
    my $self = shift;
    my (%params) = @_;

    my $query = $params{query};
    my $rs = $self->expanded_coverage($query);

    my $curr_test;
    my $data;
    my $end = 0;

    my $run_id;
    my $iterator = sub {
        while (1) {
            return undef if $end;

            my $out;

            my $item = $rs->next;
            if (!$item) {
                $end  = 1;
                $out  = $data;
                $data = undef;
                return $out;
            }

            $run_id //= $item->run_id;
            die "Different run id!" if $run_id ne $item->run_id;

            my $fields = $item->human_fields;
            my $test   = $fields->{test_file};
            if (!$curr_test || $curr_test ne $test) {
                $out  = $data;
                $data = undef;

                $curr_test = $test;

                $data = {
                    test       => $test,
                    aggregator => 'Test2::Harness::Log::CoverageAggregator::ByTest',
                    files      => {},
                };

                $data->{manager} = $fields->{manager} if $fields->{manager};
            }

            my $source = $fields->{source_file};
            my $sub    = $fields->{source_sub};
            my $meta   = $fields->{metadata};

            $data->{files}->{$source}->{$sub} = $meta;

            return $out if $out;
        }
    };

    return $iterator if $params{iterator};

    my @out;
    while (my $item = $iterator->()) {
        push @out => $item;
    }

    return @out;
}

sub rerun_data {
    my $self = shift;

    my $files = $self->jobs->search(
        {},
        {
            join => 'test_file', order_by => 'test_file.filename'
        },
    );

    my $data = {};

    while (my $file = $files->next) {
        next if $file->is_harness_out;

        my $name = $file->file || next;

        my $row = $data->{$name} //= {};

        for my $try ($file->job_tries) {
            $row->{retry}++ if $try->job_try_ord;
            $row->{end}++ if $try->ended;
            $row->{$try->fail ? 'fail' : 'pass'}++;
        }
    }

    return $data;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Run - DBIC Result class for the Run table.

=cut
