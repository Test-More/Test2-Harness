# HARNESS-CONFLICTS YATH
# HARNESS-DURATION-SLOW
use Test2::V0;

use File::Spec;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

sub clean_output {
    my $out = shift;

    $out->{output} =~ s/^.*duration.*$//m;
    $out->{output} =~ s/^.*Wrote log file:.*$//m;
    $out->{output} =~ s/^.*Wrote archive:.*$//m;
    $out->{output} =~ s/^.*Symlinked to:.*$//m;
    $out->{output} =~ s/^.*Linked log file:.*$//m;
    $out->{output} =~ s/^\s*(?:Run\s+)?Wall Time:.*$//m;
    $out->{output} =~ s/^\s*Cumulative Job Time:.*$//m;
    $out->{output} =~ s/^\s*Aggregate Job Stats:\s*$//m;
    $out->{output} =~ s/^\s*CPU Time:.*s\)//m;
    $out->{output} =~ s/^\s*CPU Usage:.*%//m;
    $out->{output} =~ s/^\s*-+$//m;
    $out->{output} =~ s/^\s+$//m;
    $out->{output} =~ s/\n+/\n/g;
    $out->{output} =~ s/^\s+//mg;
    $out->{output} =~ s/\e\[0m//mg;

    # Can remove this once the fixme is removed
    $out->{output} =~ s/^FIXME: publish should send log to server$//gm;

    # Normalize display job numbers: parallel jobs complete in non-deterministic
    # order so the renderer assigns job 1/2/... differently each run.
    $out->{output} =~ s/\bjob\s+\d+\b/job N/g;

    # Strip absolute-path prefix from any repo-rooted `t/...`
    # reference anywhere in the output. The recorded archive
    # carries paths from whichever machine generated it (e.g.
    # /home/teo/git/Test2-Harness/t/Yath/integration/replay/fail.tx);
    # the golden file holds the canonical repo-relative form
    # (t/Yath/integration/replay/fail.tx). Catches the diag line
    # `(  DIAG  )  job N    at <abs>/t/... line N`, the failure
    # summary table cells `| <abs>/t/... |`, and any other
    # context where a future renderer change might surface an
    # absolute path -- so the test stays portable across
    # machines without case-by-case patching.
    $out->{output} =~ s{/(?:[^/\s|]+/)+(t/[\w./-]+)}{$1}g;

    my @lines;
    my $start;
    for my $line (split /\n/, $out->{output}) {
        $start++ if $line =~ m/^(\[|\()/;

        next unless $start;

        push @lines => $line;
    }

    $out->{output} = join "\n" => @lines;
}

my $archive = File::Spec->catfile($dir, 'run.yath');
my $golden  = File::Spec->catfile($dir, 'expected_output.txt');

open(my $fh, '<', $golden) or die "Cannot read golden file '$golden': $!";
my $expected = do { local $/; <$fh> };
close($fh);
chomp $expected;

yath(
    command => 'replay',
    args    => [$archive],
    exit    => T(),
    test    => sub {
        my $out = shift;
        clean_output($out);
        is($out->{output}, $expected, "Replay output matches committed golden");
    },
);

done_testing;
