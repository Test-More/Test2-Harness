use Test2::V0;
use Test2::Require::AuthorTesting;
# HARNESS-DURATION-LONG

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;
use Test2::Harness::Util qw/clean_path/;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "Cannot fork, skipping preload test"
    if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $tx = __FILE__ . 'x';

my $tmpdir = tempdir(CLEANUP => 1);
mkdir("$tmpdir/Preload") or die "($tmpdir/Preload) $!";

{
    open(my $fh, '>', "$tmpdir/Preload.pm") or die "Could not create preload: $!";
    print $fh <<'    EOT';
package Preload;
use strict;
use warnings;

use Test2::Harness::Preload;

stage A => sub {
    default();

    # Do like this to avoid blacklisting
    preload sub { require Preload::Flux };
};

1;
    EOT
}

sub touch {
    my ($inject) = @_;
    my $path = "$tmpdir/Preload/Flux.pm";
    note "Touching $path...";

    open(my $fh, '>', $path) or die $!;

    print $fh <<"    EOT";
package Preload::Flux;
use strict;
use warnings;

sub foo { 'foo' }

$inject

1;
    EOT

    close($fh);

    sleep 5;
}

touch('$Preload::Flux::VAR = "initial";');

yath(
    command => 'start',
    pre     => ["-D$tmpdir"],
    args    => ["-I$tmpdir", '-PPreload'],
    exit    => 0,
);

yath(
    command => 'status',
    test    => sub {
        my $out = shift;
        like(
            $out->{output},
            qr{A\s*\|\s*UP},
            "Stage A is UP"
        );
    },
);

yath(
    command => 'run',
    args => [$tx, '::', 'initial'],
    exit => 0,
);

touch('$Preload::Flux::VAR = "Syntax Error $bob";');

yath(
    command => 'status',
    test    => sub {
        my $out = shift;
        like(
            $out->{output},
            qr{A\s*\|\s*DOWN},
            "Stage A is DOWN"
        );
    },
);

touch('$Preload::Flux::VAR = "fixed";');

yath(
    command => 'status',
    test    => sub {
        my $out = shift;
        like(
            $out->{output},
            qr{A\s*\|\s*UP},
            "Stage A is UP"
        );
    },
);

yath(
    command => 'run',
    args => [$tx, '::', 'fixed'],
    exit => 0,
);


yath(command => 'stop', exit => 0);

done_testing;
