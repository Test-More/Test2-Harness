use strict;
use warnings;

BEGIN {$ENV{T2_HARNESS_UI_ENV} = 'dev'}

use Test2::Harness::UI;
use Test2::Harness::UI::Config;
use Test2::Harness::UI::Importer;

my ($dsn, $uploads) = @ARGV;

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn    => $dsn,
    dbi_user   => '',
    dbi_pass   => '',
    upload_dir => $uploads,
);

Test2::Harness::UI::Importer->new(config => $config, max => 2)->run;
