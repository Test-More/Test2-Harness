package App::Yath::Schema::DBIC;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use base 'DBIx::Class::Schema';

use Carp qw/confess/;
use Exporter 'import';

use Test2::Util::UUID qw/uuid2bin bin2uuid/;

our @EXPORT_OK = qw/
    is_sqlite
    is_postgresql
    is_mysql
    is_mariadb
    is_percona
    can_store_null_character
    format_uuid_for_db
    format_uuid_for_app
/;

sub is_sqlite     { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/SQLite/     ? 1 : 0 }
sub is_postgresql { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/PostgreSQL/ ? 1 : 0 }
sub is_mariadb    { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/MariaDB/    ? 1 : 0 }
sub is_percona    { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/Percona/    ? 1 : 0 }

sub is_mysql {
    return 1 if is_mariadb();
    return 1 if is_percona();
    return 1 if ($App::Yath::Schema::DBIC::LOADED // '') =~ m/MySQL/;
    return 0;
}

sub can_store_null_character {
    return 0 if is_postgresql();
    return 1;
}

sub format_uuid_for_db {
    shift if @_ && defined $_[0] && !ref($_[0]) && $_[0] eq __PACKAGE__;
    my ($uuid) = @_;
    return $uuid unless is_percona();
    return uuid2bin($uuid);
}

sub format_uuid_for_app {
    shift if @_ && defined $_[0] && !ref($_[0]) && $_[0] eq __PACKAGE__;
    my ($uuid_bin) = @_;
    return $uuid_bin unless is_percona();
    return bin2uuid($uuid_bin);
}

1;
