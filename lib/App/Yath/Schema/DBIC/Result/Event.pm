package App::Yath::Schema::DBIC::Result::Event;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_percona format_uuid_for_app format_uuid_for_db/;

use App::Yath::Schema::ImportModes();
use App::Yath::Renderer::Default::Composer();

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("events");

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
    "trace_uuid" => do {
        if (is_percona()) {
            +{
                data_type   => "binary",
                is_nullable => 1,
                size        => 16,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "uuid",
                is_nullable => 1,
                size        => 16,
            };
        }
        elsif (is_sqlite()) {
            +{
                data_type     => "uuid",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        else {
            +{
                data_type   => "uuid",
                is_nullable => 1,
            };
        }
    },
    "parent_uuid" => do {
        if (is_percona()) {
            +{
                data_type      => "binary",
                is_foreign_key => 1,
                is_nullable    => 1,
                size           => 16,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type      => "uuid",
                is_foreign_key => 1,
                is_nullable    => 1,
                size           => 16,
            };
        }
        elsif (is_sqlite()) {
            +{
                data_type      => "uuid",
                default_value  => \"null",
                is_foreign_key => 1,
                is_nullable    => 1,
            };
        }
        else {
            +{
                data_type      => "uuid",
                is_foreign_key => 1,
                is_nullable    => 1,
            };
        }
    },
    "event_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "events_event_id_seq") : ()),
    },
    "job_try_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "parent_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "event_idx" => {
        data_type   => "integer",
        is_nullable => 0,
    },
    "event_sdx" => {
        data_type   => "integer",
        is_nullable => 0,
    },
    "stamp" => do {
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
    "nested" => do {
        if (is_sqlite()) {
            +{
                data_type   => "smallintegernot",
                is_nullable => 1,
            };
        }
        else {
            +{
                data_type   => "smallint",
                is_nullable => 0,
            };
        }
    },
    "is_subtest" => do {
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
    "is_diag" => do {
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
    "is_harness" => do {
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
    "is_time" => do {
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
    "is_orphan" => do {
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
    "causes_fail" => do {
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
    "has_facets" => do {
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
    "has_binary" => do {
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
    "facets" => do {
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
    "rendered" => do {
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

__PACKAGE__->set_primary_key("event_id");
__PACKAGE__->add_unique_constraint("event_uuid_unique", ["event_uuid"]);
__PACKAGE__->add_unique_constraint(
    "job_try_id_event_idx_event_sdx_unique",
    ["job_try_id", "event_idx", "event_sdx"],
);

__PACKAGE__->has_many(
    "binaries" => "App::Yath::Schema::DBIC::Result::Binary",
    { "foreign.event_id" => "self.event_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "events_parent_uuids" => "App::Yath::Schema::DBIC::Result::Event",
    { "foreign.parent_uuid" => "self.event_uuid" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "events_parents" => "App::Yath::Schema::DBIC::Result::Event",
    { "foreign.parent_id" => "self.event_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->belongs_to(
    "job_try" => "App::Yath::Schema::DBIC::Result::JobTry",
    { job_try_id => "job_try_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "parent" => "App::Yath::Schema::DBIC::Result::Event",
    { event_id => "parent_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->belongs_to(
    "parent_uuid" => "App::Yath::Schema::DBIC::Result::Event",
    { event_uuid => "parent_uuid" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "NO ACTION",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->inflate_column(
    rendered => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('rendered', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('rendered', {}),
    },
);

__PACKAGE__->inflate_column(
    facets => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('facets', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('facets', {}),
    },
);

if (is_percona()) {
    __PACKAGE__->inflate_column(
        'event_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
    __PACKAGE__->inflate_column(
        'trace_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
    __PACKAGE__->inflate_column(
        'parent_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
}

sub run  { shift->job->run }
sub user { shift->job->run->user }

sub in_mode {
    my $self = shift;
    return App::Yath::Schema::ImportModes::event_in_mode(event => $self, @_);
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;
    return \%cols;
}

sub st_line_data {
    my $self = shift;

    my $out = $self->line_data;

    $out->{loading_subtest} = 1;

    return $out;
}

sub line_data {
    my $self = shift;
    my %cols = $self->get_all_fields;
    my %out;

    my $has_facets = $cols{has_facets} ? 1 : 0;
    my $is_orphan = $cols{is_orphan} ? 1 : 0;
    my $has_binary = $cols{has_binary} ? 1 : 0;
    my $is_parent  = $cols{is_subtest} ? 1 : 0;
    my $causes_fail = $cols{causes_fail} ? 1 : 0;

    $out{lines} = $self->rendered // [];

    if ($has_binary) {
        for my $binary ($self->binaries) {
            my $filename = $binary->filename;

            push @{$out{lines}} => [
                'binary',
                $binary->is_image ? 'IMAGE' : 'BINARY',
                $filename,
                $binary->binary_id,
            ];
        }
    }

    $out{facets}    = $has_facets;
    $out{orphan}    = $is_orphan;
    $out{is_parent} = $is_parent;
    $out{is_fail}   = $causes_fail;

    if ($cols{parent_id}) {
        $out{parent_id} = $cols{parent_id};
        $out{parent_uuid} = ref($cols{parent_uuid}) ? $cols{parent_uuid}->event_uuid : $cols{parent_uuid};
    }

    $out{nested} = $cols{nested} // 0;

    $out{event_id} = $cols{event_id};
    $out{event_uuid} = $cols{event_uuid};

    return \%out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Event - DBIC Result class for the Event table.

=cut
