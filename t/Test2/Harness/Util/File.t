use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File';

use ok $CLASS;

can_ok($CLASS, qw/name done set_done/);

like(
    dies { $CLASS->new },
    qr/'name' is a required attribute/,
    "Must provide the 'name' attribute"
);

open(my $tmpfh, '<', __FILE__) or die "Could not open file: $!";
my $zed = $CLASS->new(name => __FILE__, fh => $tmpfh);
is($zed->fh, $tmpfh, "saved fh");
is($tmpfh->blocking, 0, "fh was set to non-blocking");
$zed = undef;

my $one = $CLASS->new(name => __FILE__);
my $two = $CLASS->new(name => '/some/super/fake/file/that must not exist');
ok($one->exists, "This file exists");
ok(!$two->exists, "The file does not exist");

is($one->decode('xxx'), 'xxx', "base class decode does nothing");
is($one->encode('xxx'), 'xxx', "base class encode does nothing");

ok(my $fh = $one->open_file, "opened file (for reading)");
ok(dies { $two->open_file }, "Cannot open file (for reading)");

like(
    $one->maybe_read,
    qr/^\Quse Test2::Bundle::Extended -target => 'Test2::Harness::Util::File';\E$/m,
    "Can read file (using maybe_read)"
);

is(
    $two->maybe_read,
    undef,
    "maybe_read returns undef for non-existant file"
);

like(
    $one->read,
    qr/^\Quse Test2::Bundle::Extended -target => 'Test2::Harness::Util::File';\E$/m,
    "Can read file"
);

ok(dies { $two->read }, "read() dies on missing file");

close($fh);

ok($fh = $one->fh, "Can generate an FH");
is($one->fh, $fh, "FH is remembered");
is($fh->blocking, 0, "FH is non-blocking");

close($fh);

is($two->fh, undef, "return undef for missing file");

$one->set_done(1);
is($one->done, 1, "can set done");
$one->reset;
ok(!$one->{_fh}, "removed fh");
ok(!$one->done, "cleared done flag");

$two->reset;
is($two->read_line, undef, "cannot read lines from missing file");

is(
    $one->read_line,
    "use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File';\n",
    "Got first line"
);

while(my $l = $one->read_line) { 1 }

is($one->read_line, undef, "no line to read yet");
$one->set_done(1);

is(
    $one->read_line,
    "This line MUST be here, and MUST not end with a newline.",
    "Got final line with no terminator"
);

$one->reset;
is(
    $one->read_line,
    "use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File';\n",
    "Got first line again after reset"
);

#TODO: write (it is atomic)

done_testing;

__END__

This line MUST be here, and MUST not end with a newline.