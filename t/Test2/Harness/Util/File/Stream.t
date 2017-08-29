use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File::Stream';
use File::Temp qw/tempfile/;

use ok $CLASS;

my ($wh, $filename) = tempfile("test-$$-XXXXXXXX", TMPDIR => 1);

print $wh "line1\nline2\nline3\nline";
$wh->flush;

ok(my $one = $CLASS->new(name => $filename), "New instance");

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

print $wh "4\nline5";
$wh->flush;

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

print $wh "\nline6";
$wh->flush;

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

unlink($filename);
done_testing;
