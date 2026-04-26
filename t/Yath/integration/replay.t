# HARNESS-CONFLICTS YATH
# HARNESS-DURATION-SLOW
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
use Test2::Harness2::Util::File::JSONL;
use Test2::Harness2::Util::JSON qw/decode_json/;

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
    $out->{output} =~ s/^\s*Wall Time:.*seconds//m;
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
    # order so the renderer assigns job 1/2/... differently each run. Replace
    # all "job N" sequences with a "job N" sentinel so both sides match.
    $out->{output} =~ s/\bjob\s+\d+\b/job N/g;

    my @lines;
    my $start;
    for my $line (split /\n/, $out->{output}) {
        $start++ if $line =~ m/^(\[|\()/;

        next unless $start;

        push @lines => $line;
    }

    # Live (`yath test`) and replay emit the same per-job lines but in
    # different orders, depending on how the failed job's diagnostics
    # (FAIL / DIAG / REASON) interleave with another job's status line.
    # Trying to group diag lines back to "their" status line is fragile
    # because diag lines carry only `job N` (already normalised above) --
    # there is no filename to disambiguate. The robust fix is to
    # canonicalise the order of every `job N`-prefixed line: collect
    # consecutive runs of them, sort the run, flush. Non-job lines (the
    # "The following jobs failed:" table, the "Yath Result Summary" block,
    # etc.) pass through verbatim so the file's overall narrative stays
    # intact.
    my @normalized;
    my @run;
    for my $line (@lines) {
        if ($line =~ /\bjob\s+N\b/) {
            push @run => $line;
        }
        else {
            push @normalized => sort @run if @run;
            @run = ();
            push @normalized => $line;
        }
    }
    push @normalized => sort @run if @run;

    $out->{output} = join "\n" => @normalized;
}

my $out1 = yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    log     => 1,
    exit    => T(),
    test    => sub {
        my $out = shift;
        clean_output($out);

        like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the log");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the log");

    },
);

my $logfile = $out1->{log}->name;

yath(
    command => 'replay',
    args    => [$logfile],
    exit => $out1->{exit},
    test => sub {
        my $out2 = shift;
        clean_output($out2);
        clean_output($out1);

        is($out2->{output}, $out1->{output}, "Replay has identical output to original");
    },
);

done_testing;
