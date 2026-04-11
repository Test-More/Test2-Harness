package App::Yath::Schema::DBIC::Result::Job;
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

__PACKAGE__->table("jobs");

__PACKAGE__->add_columns(
    "job_uuid" => do {
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
    "job_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "jobs_job_id_seq") : ()),
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
    "is_harness_out" => do {
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
    "failed" => do {
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
    "passed" => do {
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
);

__PACKAGE__->set_primary_key("job_id");
__PACKAGE__->add_unique_constraint("job_uuid_unique", ["job_uuid"]);

__PACKAGE__->has_many(
    "jobs_tries" => "App::Yath::Schema::DBIC::Result::JobTry",
    { "foreign.job_id" => "self.job_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->belongs_to(
    "run" => "App::Yath::Schema::DBIC::Result::Run",
    { run_id => "run_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "test_file" => "App::Yath::Schema::DBIC::Result::TestFile",
    { test_file_id => "test_file_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

if (is_percona()) {
    __PACKAGE__->inflate_column(
        'job_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
}

*job_tries = *jobs_tries;

sub file {
    my $self = shift;
    my %cols = $self->get_all_fields;

    return $cols{file}     if exists $cols{file};
    return $cols{filename} if exists $cols{filename};

    my $test_file = $self->test_file or return undef;
    return $test_file->filename;
}

sub shortest_file {
    my $self = shift;
    my $file = $self->file or return undef;

    return $1 if $file =~ m{([^/]+)$};
    return $file;
}

sub short_file {
    my $self = shift;
    my $file = $self->file or return undef;

    return $1 if $file =~ m{/(t2?/.*)$}i;
    return $1 if $file =~ m{([^/\\]+\.(?:t2?|pl))$}i;
    return $file;
}

sub complete {
    my $self = shift;

    my @tries = $self->job_tries or return 0;

    my $to_see = 1;
    for my $try (@tries) {
        $to_see--;
        return 0 unless $try->complete;
        $to_see++ if $try->retry;
    }

    return $to_see ? 0 : 1;
}

sub sig {
    my $self = shift;

    my $out = join ';' => map { $_->sig } sort { $a->job_try_ord <=> $b->job_try_ord } $self->jobs_tries;
    $out //= ';';
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;

    $cols{short_file}    = $self->short_file;
    $cols{shortest_file} = $self->shortest_file;

    return \%cols;
}

my @GLANCE_FIELDS = qw{ job_uuid is_harness_out };

sub glance_data {
    my $self = shift;
    my %params = @_;

    my $try_id = $params{try_id};

    my %cols = $self->get_all_fields;

    my %data;
    @data{@GLANCE_FIELDS} = @cols{@GLANCE_FIELDS};

    $data{file}          = $self->file;
    $data{short_file}    = $self->short_file;
    $data{shortest_file} = $self->shortest_file;

    my @out;

    for my $try ($self->jobs_tries) {
        next if $try_id && $try->job_try_id != $try_id;
        push @out => {%data, %{$try->glance_data}};
    }

    unless (@out) {
        push @out => {%data, status => 'pending'}
    }

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Job - DBIC Result class for the Job table.

=cut
