use Test2::V0;

use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v'],
    exit    => 0,
    test    => sub {
        my $todo = todo "FIXME #216";
        my $out  = shift;

        chomp(my $want = <<'        EOT');
[  PASS  ]  job  1  +~buffered
[  PASS  ]  job  1    + buffered ok
[  PLAN  ]  job  1    | Expected assertions: 1
            job  1    ^
[  PLAN  ]  job  1    Expected assertions: 1
        EOT

        like($out->{output}, qr{\Q$want\E}, "Got the desired output");
    },
);

done_testing;
