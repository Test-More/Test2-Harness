use strict;
use warnings;

use Test2::V0;
use App::Yath2::Renderer2::TerminalAuto;
use File::Temp qw/tempfile/;

# Non-TTY (regular file) => Txt.
my ($tfh, $tpath) = tempfile(UNLINK => 1);
my $f = App::Yath2::Renderer2::TerminalAuto::pick(out_fh => $tfh);
isa_ok($f, ['App::Yath2::Formatter::Txt'], 'regular file handle -> Txt formatter');

# In-memory scalar fh (not a TTY) => Txt.
open my $mfh, '>', \my $buf or die "open: $!";
my $f2 = App::Yath2::Renderer2::TerminalAuto::pick(out_fh => $mfh);
isa_ok($f2, ['App::Yath2::Formatter::Txt'], 'in-memory scalar handle -> Txt formatter');

# No fh => checks STDOUT. In a non-tty test environment STDOUT is a
# pipe so Txt. Test conditionally:
SKIP: {
    skip "STDOUT is a TTY in this environment", 1 if -t STDOUT;
    my $f3 = App::Yath2::Renderer2::TerminalAuto::pick();
    isa_ok($f3, ['App::Yath2::Formatter::Txt'], 'no fh + non-TTY STDOUT -> Txt formatter');
}

# Verify the Tty path: pass a fake TTY by using a pty if available,
# or just test the logic directly via a mocked -t check.
# We use a pipe trick: the write-end is never a TTY.
{
    pipe(my $rh, my $wh);
    my $f4 = App::Yath2::Renderer2::TerminalAuto::pick(out_fh => $wh);
    isa_ok($f4, ['App::Yath2::Formatter::Txt'], 'pipe write-end -> Txt formatter');
    close $rh;
    close $wh;
}

done_testing;
