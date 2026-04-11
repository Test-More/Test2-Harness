use strict;
use warnings;
use Test2::V0;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::Parser qw/parse_dump/;

my $sqlite_path = 'author_tools/t/fixtures/loader-sample-sqlite-User.pm';
open(my $fh, '<', $sqlite_path) or die "open $sqlite_path: $!";
my $content = do { local $/; <$fh> };
close $fh;

my $parsed = parse_dump($content);

is($parsed->{package}, 'App::Yath::Schema::Result::User', 'package name parsed');
is($parsed->{table},   'users',                            'table name parsed');

is(
    $parsed->{components},
    [
        "InflateColumn::DateTime",
        "InflateColumn::Serializer",
        "InflateColumn::Serializer::JSON",
    ],
    'components parsed',
);

# First column is user_id with integer/auto_increment.
is($parsed->{columns}[0]{name}, 'user_id', 'first column name');
is(
    $parsed->{columns}[0]{spec}{data_type},
    'integer',
    'user_id data_type (SQLite)',
);
is($parsed->{columns}[0]{spec}{is_auto_increment}, 1, 'user_id is_auto_increment');

is($parsed->{primary_key}, ['user_id'], 'primary key parsed');

ok(
    (grep { $_->{name} eq 'username_unique' } @{ $parsed->{unique_constraints} }),
    'username_unique constraint parsed',
);

my ($api_keys_rel) = grep { $_->{name} eq 'api_keys' } @{ $parsed->{relationships} };
ok($api_keys_rel, 'api_keys relationship parsed');
is($api_keys_rel->{kind},   'has_many', 'api_keys kind');
is($api_keys_rel->{target}, 'App::Yath::Schema::Result::ApiKey', 'api_keys target');

done_testing;
