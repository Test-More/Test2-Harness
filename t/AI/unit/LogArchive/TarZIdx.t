use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use App::Yath2::LogArchive;

use App::Yath2::LogArchive::TarZIdx;

my $src = tempdir(CLEANUP => 1);
mkdir "$src/sub" or die $!;
open my $fh, '>', "$src/a.txt" or die $!;
print $fh "alpha\n" x 200;
close $fh;
open $fh, '>', "$src/b.txt" or die $!;
print $fh "BB\n";
close $fh;
open $fh, '>', "$src/sub/c.txt" or die $!;
print $fh "ccc\n" x 50;
close $fh;

my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.tar.zidx', UNLINK => 1);
unlink $out;

App::Yath2::LogArchive->open(dir => $src)->archive($out);
ok(-s $out, 'output non-empty');

my $la = App::Yath2::LogArchive->open(path => $out);
ok(
    ref($la) eq 'App::Yath2::LogArchive::TarZIdx',
    'reader resolves to TarZIdx backend (' . ref($la) . ')'
);

my @files = sort $la->list_files;
is(\@files, ['a.txt', 'b.txt', 'sub/c.txt'], 'list_files');

ok($la->has_file('a.txt'),     'has_file a.txt');
ok($la->has_file('sub/c.txt'), 'has_file sub/c.txt');
ok(!$la->has_file('missing'),  '!has_file missing');

for my $name ('a.txt', 'b.txt', 'sub/c.txt') {
    my $rfh = $la->read_file($name);
    local $/;
    my $got = <$rfh>;
    close $rfh;

    open my $orig, '<', "$src/$name" or die $!;
    binmode $orig;
    my $expect = do { local $/; <$orig> };
    close $orig;

    is($got, $expect, "round-trip content for $name");
}

# Verify standard tar can list the entries (compatibility check).
my @tar_entries = `tar -tf $out 2>/dev/null`;
chomp @tar_entries;
my %tar_set = map { $_ => 1 } @tar_entries;
ok($tar_set{'a.txt.zst'},       'standard tar sees a.txt.zst entry');
ok($tar_set{'sub/c.txt.zst'},   'standard tar sees sub/c.txt.zst entry');
ok($tar_set{'__index__.json.zst'}, 'standard tar sees __index__.json.zst entry');

done_testing;
