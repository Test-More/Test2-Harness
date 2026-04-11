package App::Yath::Schema::DBIC::Result::User;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_mysql/;

use Test2::Util::UUID qw/gen_uuid/;
use Carp qw/croak/;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash en_base64 de_base64);

use constant COST => 8;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("users");

__PACKAGE__->add_columns(
    "user_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "users_user_id_seq") : ()),
    },
    "pw_hash" => {
        data_type   => "varchar",
        is_nullable => 1,
        size        => 31,
        (is_mysql() ? () : (default_value => \"null")),
    },
    "pw_salt" => {
        data_type   => "varchar",
        is_nullable => 1,
        size        => 22,
        (is_mysql() ? () : (default_value => \"null")),
    },
    "role" => do {
        if (is_sqlite()) {
            +{
                data_type     => "text",
                default_value => "user",
                is_nullable   => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "enum",
                default_value => "user",
                is_nullable   => 0,
                extra         => {
                    custom_type_name => "user_type",
                    list             => ["admin", "user"],
                },
            };
        }
        else {
            +{
                data_type     => "enum",
                default_value => "user",
                is_nullable   => 0,
                extra         => { list => ["admin", "user"] },
            };
        }
    },
    "username" => {
        data_type   => is_postgresql() ? "citext" : "varchar",
        is_nullable => 0,
        (is_postgresql() ? () : (size => 64)),
    },
    "realname" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
);

__PACKAGE__->set_primary_key("user_id");
__PACKAGE__->add_unique_constraint("username_unique", ["username"]);

__PACKAGE__->has_many(
    "api_keys" => "App::Yath::Schema::DBIC::Result::ApiKey",
    { "foreign.user_id" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "emails" => "App::Yath::Schema::DBIC::Result::Email",
    { "foreign.user_id" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "permissions" => "App::Yath::Schema::DBIC::Result::Permission",
    { "foreign.user_id" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->might_have(
    "primary_email" => "App::Yath::Schema::DBIC::Result::PrimaryEmail",
    { "foreign.user_id" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "projects" => "App::Yath::Schema::DBIC::Result::Project",
    { "foreign.owner" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "reports" => "App::Yath::Schema::DBIC::Result::Reporting",
    { "foreign.user_id" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "runs" => "App::Yath::Schema::DBIC::Result::Run",
    { "foreign.user_id" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "session_hosts" => "App::Yath::Schema::DBIC::Result::SessionHost",
    { "foreign.user_id" => "self.user_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

sub new {
    my $class = shift;
    my ($attrs) = @_;

    if (my $pw = delete $attrs->{password}) {
        my $salt = $class->gen_salt;
        my $hash = bcrypt_hash({key_nul => 1, cost => COST, salt => $salt}, $pw);

        $attrs->{pw_hash} = en_base64($hash);
        $attrs->{pw_salt} = en_base64($salt);
    }

    my $new = $class->next::method($attrs);

    return $new;
}

sub verify_password {
    my $self = shift;
    my ($pw) = @_;

    my $hash = en_base64(bcrypt_hash({key_nul => 1, cost => COST, salt => de_base64($self->pw_salt)}, $pw));
    return $hash eq $self->pw_hash;
}

sub set_password {
    my $self = shift;
    my ($pw) = @_;

    my $salt = $self->gen_salt;
    my $hash = bcrypt_hash({key_nul => 1, cost => COST, salt => $salt}, $pw);

    $self->update({pw_hash => en_base64($hash), pw_salt => en_base64($salt)});
}

sub gen_salt {
    my $salt = '';
    $salt .= chr(rand() * 256) while length($salt) < 16;
    return $salt;
}

sub gen_api_key {
    my $self = shift;
    my ($name) = @_;

    croak "Must provide a key name"
        unless defined($name);

    return $self->result_source->schema->resultset('ApiKey')->create(
        {
            user_id => $self->user_id,
            value   => gen_uuid(),
            status  => 'active',
            name    => $name,
        }
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::User - DBIC Result class for the User table.

=cut
