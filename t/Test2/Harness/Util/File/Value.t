use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File::Value';

use ok $CLASS;

isa_ok($CLASS, 'Test2::Harness::Util::File');

my $one = $CLASS->new(name => __FILE__);

my $val = $one->read;
chomp(my $no_tail = $val);
is($val, $no_tail, "trailing newline was removed from the value");

$val = $one->read_line;
is(
    $val,
    "use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File::Value';",
    "got line, no newline"
);

done_testing;
