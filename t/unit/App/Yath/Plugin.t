use Test2::V0 -target => 'App::Yath::Plugin';

isa_ok($CLASS, ['Test2::Harness::Plugin'], "Subclasses Test2::Harness::Plugin");

can_ok($CLASS, ['finish'], "finish() is defined");
is([$CLASS->finish], [], "finish returns an empty list in list context");
is($CLASS->finish, undef, "finish returns undef in scalar context");

ok(!$CLASS->can('sort_files'), "sort_files is not defined by default");
ok(!$CLASS->can('handle_event'), "handle_event is not defined by default");

done_testing;
