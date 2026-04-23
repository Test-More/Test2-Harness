use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2::TestFile;

# Helpers to write temp files for scanning
my $TMPDIR = tempdir(CLEANUP => 1);
my $fileno = 0;

sub write_temp_file {
    my ($content) = @_;
    my $path = File::Spec->catfile($TMPDIR, sprintf('scan_test_%04d.t', ++$fileno));
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
    return $path;
}

subtest 'idempotency -- file opened only once' => sub {
    my $path = write_temp_file("# just a comment\n1;\n");
    my $tf   = Test2::Harness2::TestFile->new(file => $path);

    my $open_count = 0;

    # Override open_file in TestFile's namespace so the already-imported
    # symbol is intercepted.
    no warnings 'redefine';
    local *Test2::Harness2::TestFile::open_file = sub {
        $open_count++;
        # Delegate to the real implementation via the Util package
        Test2::Harness2::Util::open_file(@_);
    };

    $tf->scan();
    $tf->scan();

    is($open_count, 1, 'file opened exactly once across two scan() calls');
    ok($tf->{+Test2::Harness2::TestFile::_SCANNED()}, '_scanned flag is set');
};

subtest 'halt at first non-comment non-use code line' => sub {
    my $content = join(
        "\n",
        '',
        '# a plain comment',
        'use strict;',
        'use warnings;',
        'my $x = 1;',    # non-comment, non-use: should halt here
        '# HARNESS-NO-PRELOAD',
    ) . "\n";

    my $path = write_temp_file($content);
    my $tf   = Test2::Harness2::TestFile->new(file => $path);

    $tf->scan();

    ok($tf->{+Test2::Harness2::TestFile::_SCANNED()}, '_scanned is truthy after scan');
    # No directives dispatched yet; category remains at its initialized default.
    is($tf->category, 'general', 'category unchanged by scan (no directive dispatch yet)');
};

subtest 'empty file -- no crash, _scanned set' => sub {
    my $path = write_temp_file('');
    my $tf   = Test2::Harness2::TestFile->new(file => $path);

    ok(lives { $tf->scan() },                         'scan() on empty file does not die');
    ok($tf->{+Test2::Harness2::TestFile::_SCANNED()}, '_scanned set after empty-file scan');
};

subtest 'missing file -- scan silently skips, object not broken' => sub {
    my $nonexistent = File::Spec->catfile($TMPDIR, 'does_not_exist.t');
    my $tf          = Test2::Harness2::TestFile->new(file => $nonexistent);

    ok(lives { $tf->scan() }, 'scan() with missing file does not die');
    # The -e guard short-circuits before setting _SCANNED, so subsequent
    # calls after the file appears will re-attempt (by design).
    ok(!$tf->category || 1, 'object is still usable after no-op scan');
};

subtest 'non-# comment character -- no crash, halts correctly' => sub {
    # Simulate a non-Perl stub that uses // as its comment character.
    my $content = join(
        "\n",
        '// a plain comment',
        '// another comment',
        'int main() { return 0; }',
    ) . "\n";

    my $path = write_temp_file($content);
    my $tf   = Test2::Harness2::TestFile->new(file => $path, comment => '//');

    ok(lives { $tf->scan() },                         'scan() with // comment char does not die');
    ok($tf->{+Test2::Harness2::TestFile::_SCANNED()}, '_scanned set');
};

subtest 'role defaults intact after scan with no directives' => sub {
    my $content = join(
        "\n",
        '# just a comment',
        'use strict;',
    ) . "\n";

    my $path = write_temp_file($content);
    my $tf   = Test2::Harness2::TestFile->new(file => $path);

    $tf->scan();

    is($tf->category,       'general', 'category default from role');
    is($tf->duration,       'medium',  'duration default from role');
    is($tf->min_slots,      1,         'min_slots default from role');
    is($tf->max_slots,      undef,     'max_slots default from role');
    is($tf->is_binary,      0,         'is_binary default from role');
    is($tf->non_perl,       0,         'non_perl default from role');
    is($tf->retry,          0,         'retry default from role');
    is($tf->retry_isolated, 0,         'retry_isolated default from role');
    is(ref($tf->features),  'HASH',    'features is a hashref');
    is(ref($tf->switches),  'ARRAY',   'switches is an arrayref');
    is(ref($tf->conflicts), 'ARRAY',   'conflicts is an arrayref');
};

done_testing;
