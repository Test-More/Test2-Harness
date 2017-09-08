use Test2::Require::Module 'Test::Class::Moose::Load';
use Test::Class::Moose::Load 't/lib/TestsFor';
use Test::Class::Moose::Runner;
Test::Class::Moose::Runner->new->runtests;
