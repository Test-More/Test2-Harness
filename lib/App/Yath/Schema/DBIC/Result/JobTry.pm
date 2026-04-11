package App::Yath::Schema::DBIC::Result::JobTry;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_mysql is_percona format_uuid_for_app format_uuid_for_db/;

use App::Yath::Schema::ImportModes qw/record_all_events mode_check/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("job_tries");

__PACKAGE__->add_columns(
    "job_try_uuid" => do {
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
    "job_try_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "job_tries_job_try_id_seq") : ()),
    },
    "job_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "pass_count" => {
        data_type   => is_sqlite() ? "integer" : "bigint",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "fail_count" => {
        data_type   => is_sqlite() ? "integer" : "bigint",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "exit_code" => {
        data_type   => "integer",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "launch" => do {
        if (is_sqlite()) {
            +{
                data_type     => "datetime",
                default_value => \"null",
                is_nullable   => 1,
                size          => 6,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "timestamp with time zone",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        elsif (is_percona()) {
            +{
                data_type                 => "datetime",
                datetime_undef_if_invalid => 1,
                is_nullable               => 1,
            };
        }
        else {
            +{
                data_type                 => "timestamp",
                datetime_undef_if_invalid => 1,
                is_nullable               => 1,
            };
        }
    },
    "start" => do {
        if (is_sqlite()) {
            +{
                data_type     => "datetime",
                default_value => \"null",
                is_nullable   => 1,
                size          => 6,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "timestamp with time zone",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        elsif (is_percona()) {
            +{
                data_type                 => "datetime",
                datetime_undef_if_invalid => 1,
                is_nullable               => 1,
            };
        }
        else {
            +{
                data_type                 => "timestamp",
                datetime_undef_if_invalid => 1,
                is_nullable               => 1,
            };
        }
    },
    "ended" => do {
        if (is_sqlite()) {
            +{
                data_type     => "datetime",
                default_value => \"null",
                is_nullable   => 1,
                size          => 6,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "timestamp with time zone",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        elsif (is_percona()) {
            +{
                data_type                 => "datetime",
                datetime_undef_if_invalid => 1,
                is_nullable               => 1,
            };
        }
        else {
            +{
                data_type                 => "timestamp",
                datetime_undef_if_invalid => 1,
                is_nullable               => 1,
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
    "job_try_ord" => {
        data_type   => is_sqlite() ? "smallinteger" : "smallint",
        is_nullable => 0,
    },
    "fail" => do {
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
    "retry" => do {
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
    "duration" => {
        data_type   => is_mysql() ? "decimal" : "numeric",
        is_nullable => 1,
        size        => [14, 4],
        (is_mysql() ? () : (default_value => \"null")),
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
    "stdout" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "stderr" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
);

__PACKAGE__->set_primary_key("job_try_id");
__PACKAGE__->add_unique_constraint(
    "job_try_id_job_try_ord_unique",
    ["job_try_id", "job_try_ord"],
);

__PACKAGE__->has_many(
    "coverage" => "App::Yath::Schema::DBIC::Result::Coverage",
    { "foreign.job_try_id" => "self.job_try_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "events" => "App::Yath::Schema::DBIC::Result::Event",
    { "foreign.job_try_id" => "self.job_try_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->belongs_to(
    "job" => "App::Yath::Schema::DBIC::Result::Job",
    { job_id => "job_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->has_many(
    "job_try_fields" => "App::Yath::Schema::DBIC::Result::JobTryField",
    { "foreign.job_try_id" => "self.job_try_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "reports" => "App::Yath::Schema::DBIC::Result::Reporting",
    { "foreign.job_try_id" => "self.job_try_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->inflate_column(
    parameters => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('parameters', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('parameters', {}),
    },
);

if (is_percona()) {
    __PACKAGE__->inflate_column(
        'job_try_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
}

sub normalize_to_mode {
    my $self = shift;
    my %params = @_;

    my $mode = $params{mode} // $self->job->run->mode;

    # No need to purge anything
    return if record_all_events(mode => $mode, job => $self->job, try => $self);
    return if mode_check($mode, 'complete');

    if (mode_check($mode, 'summary', 'qvf')) {
        $self->events->delete;
        return;
    }

    my $query = {
        is_diag => 0,
        is_harness => 0,
        is_time => 0,
    };

    if (mode_check($mode, 'qvfds')) {
        $query->{'-not'} = {is_subtest => 1, nested => 0};
    }
    elsif(!mode_check($mode, 'qvfd')) {
        die "Unknown mode '$mode'";
    }

    $self->events->search($query)->delete();
}

sub short_job_try_fields {
    my $self = shift;
    my %params = @_;

    my @fields = $params{prefetched_fields} ? $self->job_try_fields : $self->job_try_fields->search(
        undef, {
            remove_columns => ['data'],
            '+select'      => ['data IS NOT NULL AS has_data'],
            '+as'          => ['has_data'],
        }
    )->all;

    my @out;
    for my $jf (@fields) {
        my $fields = {$jf->get_all_fields};

        my $has_data = delete $fields->{data};
        $fields->{has_data} //= $has_data ? \'1' : \'0';

        push @out => $fields;
    }

    return \@out;
}

my @GLANCE_FIELDS = qw{ exit_code fail job_try_ord job_try_id retry fail_count pass_count status duration };

sub sig {
    my $self = shift;

    my %cols = $self->get_all_fields;

    return join ':' => map { $_ // '' } @cols{@GLANCE_FIELDS};
}

sub glance_data {
    my $self = shift;
    my %params = @_;

    my %cols = $self->get_all_fields;

    my %data;
    @data{@GLANCE_FIELDS} = @cols{@GLANCE_FIELDS};

    $data{fields} = $self->short_job_try_fields;

    return \%data;
}

my %COMPLETE_STATUS = (complete => 1, failed => 1, canceled => 1, broken => 1);
sub complete { return $COMPLETE_STATUS{$_[0]->status} // 0 }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::JobTry - DBIC Result class for the JobTry table.

=cut
