use Test2::V0;

use App::Yath::Tester qw/yath/;
use File::Temp qw/tempdir/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $want = <<"EOT";
(  NOTE  )  job  1    valid note [\x{201c}\x{201d}\x{ff}\x{ff}]
(  NOTE  )  job  1    valid note [\x{201c}\x{201d}]
(  DIAG  )  job  1    valid diag [\x{201c}\x{201d}\x{ff}\x{ff}]
(  DIAG  )  job  1    valid diag [\x{201c}\x{201d}]
( STDOUT )  job  1    valid stdout [\x{201c}\x{201d}\x{ff}\x{ff}]
( STDOUT )  job  1    valid stdout [\x{201c}\x{201d}]
( STDERR )  job  1    valid stderr [\x{201c}\x{201d}\x{ff}\x{ff}]
( STDERR )  job  1    valid stderr [\x{201c}\x{201d}]
[  PASS  ]  job  1  + valid ok [\x{201c}\x{201d}\x{ff}\x{ff}]
[  PASS  ]  job  1  + valid ok [\x{201c}\x{201d}]
( STDOUT )  job  1    STDOUT: M\x{101}kaha
( STDERR )  job  1    STDERR: M\x{101}kaha
(  DIAG  )  job  1    DIAG: M\x{101}kaha
(  NOTE  )  job  1    NOTE: M\x{101}kaha
[  PASS  ]  job  1  + ASSERT: M\x{101}kaha
[  PASS  ]  job  1  + \x{406} \x{449}\x{435} \x{442}\x{440}\x{43e}\x{445}\x{438}
EOT

yath(
    command => 'test',
    args    => ['-v', "$dir/plugin.tx"],
    exit    => 0,
    encoding => 'utf8',
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/\Q$want\E/, "Got proper codepoints");
    },
);

yath(
    command => 'test',
    args    => ['-v', "$dir/no-plugin.tx"],
    exit    => 0,
    test    => sub {
        my $out = shift;

        utf8::encode( my $raw_want = $want );
        utf8::encode( my $u00ff = "\x{ff}" );
        $raw_want =~ s<\Q$u00ff\E><\xff>g;

        like($out->{output}, qr/\Q$raw_want\E/, "Got proper codepoints");
    },
);

done_testing;
