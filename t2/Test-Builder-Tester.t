use Test::More;
use Test::Builder::Tester;

test_out('ok 1 - foo');
ok(1, 'foo');
test_test("yup");

done_testing;
