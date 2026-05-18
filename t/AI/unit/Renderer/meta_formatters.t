use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use App::Yath2::Renderer::ArtifactWriter qw/update_meta_formatters/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

my $dir       = tempdir(CLEANUP => 1);
my $meta_path = File::Spec->catfile($dir, 'meta.json');

# --- No meta.json: silent no-op ------------------------------------------

ok(
    lives { update_meta_formatters($dir, {txt => '1.0'}) },
    'no-op when meta.json is absent',
);
ok(!-e $meta_path, 'no meta.json created');

# --- First write: merge into empty meta ----------------------------------

{
    open(my $fh, '>', $meta_path) or die "open meta: $!";
    print $fh encode_json({format_version => 1});
    close $fh;
}

my $merged = update_meta_formatters($dir, {txt => '1.0', json => '0.9'});
is(
    $merged,
    {txt => '1.0', json => '0.9'},
    'returns the merged formatters hash',
);

# Re-read on disk; meta retained format_version + got the new block.
{
    open(my $fh, '<', $meta_path) or die "open meta: $!";
    local $/;
    my $on_disk = decode_json(scalar <$fh>);
    close $fh;
    is($on_disk->{format_version}, 1, 'format_version preserved across rewrite');
    is(
        $on_disk->{formatters},
        {txt => '1.0', json => '0.9'},
        'formatters block written to disk',
    );
}

# --- Second write: merge preserves existing entries not in \%map ---------

my $merged2 = update_meta_formatters($dir, {tty => '2.0'});
is(
    $merged2,
    {txt => '1.0', json => '0.9', tty => '2.0'},
    'unspecified entries (txt, json) preserved across merge',
);

# --- Third write: same key updates the version --------------------------

my $merged3 = update_meta_formatters($dir, {txt => '1.1'});
is($merged3->{txt}, '1.1', 'existing entry updated to new version');
is($merged3->{tty}, '2.0', 'untouched entries still present');

# --- No leftover .tmp files after several rewrites ----------------------

opendir(my $dh, $dir) or die "opendir: $!";
my @leftover = grep { /^\.tmp\./ } readdir($dh);
closedir $dh;
is(\@leftover, [], 'no leftover tmp files after rewrites');

done_testing;
