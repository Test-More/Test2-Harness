package App::Yath::Schema::DBIC::Result::Coverage;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_percona format_uuid_for_app format_uuid_for_db/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("coverage");

__PACKAGE__->add_columns(
    "event_uuid" => do {
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
    "coverage_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "coverage_coverage_id_seq") : ()),
    },
    "job_try_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "coverage_manager_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "run_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "test_file_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "source_file_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "source_sub_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "metadata" => do {
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
);

__PACKAGE__->set_primary_key("coverage_id");
__PACKAGE__->add_unique_constraint(
    "run_id_job_try_id_test_file_id_source_file_id_source_sub_id_unique",
    [
        "run_id",
        "job_try_id",
        "test_file_id",
        "source_file_id",
        "source_sub_id",
    ],
);

__PACKAGE__->belongs_to(
    "coverage_manager" => "App::Yath::Schema::DBIC::Result::CoverageManager",
    { coverage_manager_id => "coverage_manager_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->belongs_to(
    "job_try" => "App::Yath::Schema::DBIC::Result::JobTry",
    { job_try_id => "job_try_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "SET NULL",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->belongs_to(
    "run" => "App::Yath::Schema::DBIC::Result::Run",
    { run_id => "run_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "source_file" => "App::Yath::Schema::DBIC::Result::SourceFile",
    { source_file_id => "source_file_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "source_sub" => "App::Yath::Schema::DBIC::Result::SourceSub",
    { source_sub_id => "source_sub_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "test_file" => "App::Yath::Schema::DBIC::Result::TestFile",
    { test_file_id => "test_file_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->inflate_column(
    metadata => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('metadata', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('metadata', {}),
    },
);

if (is_percona()) {
    __PACKAGE__->inflate_column(
        'event_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
}

sub human_fields {
    my $self = shift;

    my %cols = $self->get_all_fields;

    $cols{test_file}   //= $self->test_filename;
    $cols{source_file} //= $self->source_filename;
    $cols{source_sub}  //= $self->source_subname;
    $cols{manager}     //= $self->manager_package;

    $cols{metadata} = $self->metadata // ['*'];

    return {map { $_ => $cols{$_} } qw/test_file source_file source_sub manager metadata/};
}

sub test_filename {
    my $self = shift;
    my %cols = $self->get_all_fields;

    return $cols{test_file} // $self->test_file->filename;
}

sub source_filename {
    my $self = shift;
    my %cols = $self->get_all_fields;

    return $cols{source_file} // $self->source_file->filename;
}

sub source_subname {
    my $self = shift;
    my %cols = $self->get_all_fields;

    return $cols{source_sub} // $self->source_sub->subname;
}

sub manager_package {
    my $self = shift;
    my %cols = $self->get_all_fields;

    return $cols{manager} if $cols{manager};
    my $manager = $self->coverage_manager or return undef;
    return $manager->package;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Coverage - DBIC Result class for the Coverage table.

=cut
