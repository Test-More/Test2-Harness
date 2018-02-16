use strict;
use warnings;

BEGIN {$ENV{T2_HARNESS_UI_ENV} = 'dev'}

use Test2::Harness::UI;
use Test2::Harness::UI::Config;
use Test2::Harness::UI::Importer;

my ($dsn, $user, $pass) = @ARGV;

$user ||= '';
$pass ||= '';

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn    => $dsn,
    dbi_user   => $user,
    dbi_pass   => $pass,
);

Test2::Harness::UI::Importer->new(config => $config, max => 2)->run;
