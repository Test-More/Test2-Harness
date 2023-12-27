use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File::Stream';
use File::Temp qw/tempfile/;
# HARNESS-DURATION-SHORT

use ok $CLASS;

my ($wh, $filename) = tempfile("test-$$-XXXXXXXX", TMPDIR => 1);
print $wh "";
close($wh);

ok(my $one = $CLASS->new(name => $filename), "New instance");
$one->write("line1\n");
$one->write("line2\n");
$one->write("line3\n");
$one->write("line");

my $fh = $one->open_file('<');
is(
    [<$fh>],
    ["line1\n", "line2\n", "line3\n", "line"],
    "file written as expected"
);

is($one->read_line, "line1\n", "got first line");

is(
    [$one->poll],
    [
        "line2\n",
        "line3\n",
    ],
    "Got unseen completed lines, but not incomplete line"
);

is($one->read_line, undef, "no new lines are ready");

is(
    [$one->read],
    [
        "line1\n",
        "line2\n",
        "line3\n",
    ],
    "Read gets lines"
);

$one->write("4\n");
$one->write("line5");

is(
    [$one->read],
    [
        "line1\n",
        "line2\n",
        "line3\n",
        "line4\n",
    ],
    "Read sees the new lines"
);

is([$one->poll], ["line4\n"], "Poll sees new line after a read");

$one->write("\nline6");

is($one->read_line, "line5\n", "read_line moves to the next line");

is($one->read_line, undef, "no new lines are ready");
is([$one->poll], [], "no new lines are ready");

$one->set_done(1);

is([$one->poll], ["line6"], "got unterminated line after 'done' was set");

$one->reset;
is(
    [$one->read],
    [
        "line1\n",
        "line2\n",
        "line3\n",
        "line4\n",
        "line5\n",
    ],
    "read all lines but the last unterminated one"
);

is(
    [$one->poll],
    [
        "line1\n",
        "line2\n",
        "line3\n",
        "line4\n",
        "line5\n",
    ],
    "poll all lines but the last unterminated one"
);

$one->set_done(1);
is([$one->poll], ["line6"], "got unterminated line after 'done' was set");

$one = undef;

$one = $CLASS->new(name => $filename);
$one->seek(6);
is(
    [$one->poll],
    [
        "line2\n",
        "line3\n",
        "line4\n",
        "line5\n",
    ],
    "Was able to seek past the first item",
);

unlink($filename);
done_testing;
