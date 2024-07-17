use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

sub clean_output {
    my $out = shift;
    $out->{output} =~ s/^.*duration.*$//m;
    $out->{output} =~ s/^.*Wrote log file:.*$//m;
    $out->{output} =~ s/^.*Symlinked to:.*$//m;
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

    my @lines;
    my $start;
    for my $line (split /\n/, $out->{output}) {
        $start++ if $line =~ m/^(\[|\()/;

        next unless $start;

        push @lines => $line;
    }

    $out->{output} = join "\n" => @lines;
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
