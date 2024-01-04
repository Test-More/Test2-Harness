use Test2::V0 -target => 'App::Yath::Plugin';

isa_ok($CLASS, ['Test2::Harness::Plugin'], "Subclasses Test2::Harness::Plugin");

ok(!$CLASS->can('sort_files'), "sort_files is not defined by default");
ok(!$CLASS->can('sort_files_2'), "sort_files_2 is not defined by default");
ok(!$CLASS->can('handle_event'), "handle_event is not defined by default");

done_testing;
