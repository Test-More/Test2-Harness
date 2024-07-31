use Test2::Require::Module 'DBD::mysql';
use Test2::Require::Module 'DateTime::Format::MySQL';
use Test2::V0 -target => 'App::Yath::Schema::MySQL';

use ok $CLASS;

done_testing;
