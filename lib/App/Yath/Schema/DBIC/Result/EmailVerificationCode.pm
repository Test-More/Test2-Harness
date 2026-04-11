package App::Yath::Schema::DBIC::Result::EmailVerificationCode;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_postgresql is_percona/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("email_verification_codes");

__PACKAGE__->add_columns(
    "evcode" => do {
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
    "email_id" => {
        data_type      => "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
);

__PACKAGE__->set_primary_key("email_id");

__PACKAGE__->belongs_to(
    "email" => "App::Yath::Schema::DBIC::Result::Email",
    { email_id => "email_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::EmailVerificationCode - DBIC Result class for the EmailVerificationCode table.

=cut
