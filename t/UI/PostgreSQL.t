use Test2::Require::Module 'DBD::Pg';
use Test2::Require::Module 'DateTime::Format::Pg';
use Test2::V0 -target => 'App::Yath::Schema::PostgreSQL';

use ok $CLASS;

done_testing;
