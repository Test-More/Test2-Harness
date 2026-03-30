use Test2::V0 -target => 'Test2::Harness::Util::File::Value';

use File::Temp qw/tempdir/;
use File::Spec;

subtest 'read chomps trailing newline' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'pid.txt');

    open my $fh, '>', $path or die $!;
    print $fh "12345\n";
    close $fh;

    my $f = CLASS->new(name => $path);
    is($f->read, '12345', "read removes trailing newline");
};

subtest 'read with no trailing newline' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'noeol.txt');

    open my $fh, '>', $path or die $!;
    print $fh "value";
    close $fh;

    my $f = CLASS->new(name => $path);
    is($f->read, 'value', "read works without trailing newline");
};

subtest 'write and read round-trip' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'rtrip.txt');

    my $f = CLASS->new(name => $path);
    $f->write("stored_value\n");
    is($f->read, 'stored_value', "write and read round-trip chomps newline");
};

done_testing;
