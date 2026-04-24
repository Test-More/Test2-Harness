use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use Test2::Harness2::TestFile;
use Test2::Harness2::Util qw/open_file/;

my $tdir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} $content;
    close($fh);
    return $path;
}

subtest 'scan halts at first code line and is idempotent' => sub {
    my $path = File::Spec->catfile($tdir, 'basic.t');
    write_file(
        $path, <<'PERL',

# leading non-HARNESS comment

use strict;
use warnings;

my $x = 1;

# HARNESS-CATEGORY-ISOLATION
PERL
    );

    my $tf = Test2::Harness2::TestFile->new(file => $path);

    my $opens = 0;
    no warnings 'redefine';
    local *Test2::Harness2::TestFile::open_file = sub {
        $opens++;
        return open_file(@_);
    };
    use warnings 'redefine';

    $tf->scan;
    is($opens, 1, 'scan opens the file exactly once');
    ok($tf->{+Test2::Harness2::TestFile::_SCANNED}, '_scanned flag set');

    $tf->scan;
    is($opens, 1, 'second scan is a no-op (idempotent)');

    is($tf->category, 'general', 'no dispatch yet: category defaulted');
    is($tf->duration, 'medium',  'no dispatch yet: duration defaulted');
    is($tf->features, {},        'no dispatch yet: features empty');
    is($tf->switches, [],        'no dispatch yet: switches empty');
};

subtest 'empty file does not crash' => sub {
    my $path = File::Spec->catfile($tdir, 'empty.t');
    write_file($path, '');

    my $tf = Test2::Harness2::TestFile->new(file => $path);
    ok(lives { $tf->scan },                         'scan on empty file lives') or diag $@;
    ok($tf->{+Test2::Harness2::TestFile::_SCANNED}, '_scanned flag set');
};

subtest 'missing file returns silently' => sub {
    my $missing = File::Spec->catfile($tdir, 'nope.t');
    my $tf      = Test2::Harness2::TestFile->new(file => $missing);

    ok(lives { $tf->scan }, 'scan on missing file lives') or diag $@;
    is($tf->category, 'general', 'missing file keeps role defaults');
};

subtest 'non-# comment character' => sub {
    my $path = File::Spec->catfile($tdir, 'slash.t');
    write_file(
        $path, <<'CODE',
// non-HARNESS comment
// some header

use foo;
int main(void) { return 0; }
CODE
    );

    my $tf = Test2::Harness2::TestFile->new(
        file    => $path,
        comment => '//',
    );

    ok(lives { $tf->scan },                         'scan with non-# comment lives') or diag $@;
    ok($tf->{+Test2::Harness2::TestFile::_SCANNED}, '_scanned flag set');
};

subtest 'role defaults intact after scan with no directives' => sub {
    my $path = File::Spec->catfile($tdir, 'defaults.t');
    write_file($path, "use strict;\nmy \$x = 1;\n");

    my $tf = Test2::Harness2::TestFile->new(file => $path);
    $tf->scan;

    is($tf->min_slots,        1,         'min_slots default');
    is($tf->max_slots,        undef,     'max_slots default');
    is($tf->category,         'general', 'category default');
    is($tf->duration,         'medium',  'duration default');
    is($tf->stage,            undef,     'stage default');
    is([$tf->conflicts_list], [],        'conflicts empty');
    is($tf->features,         {},        'features empty');
    is($tf->switches,         [],        'switches empty');
    is($tf->meta,             {},        'meta empty');
    is($tf->non_perl,         0,         'non_perl default');
    is($tf->is_binary,        0,         'is_binary default');
};

done_testing;
