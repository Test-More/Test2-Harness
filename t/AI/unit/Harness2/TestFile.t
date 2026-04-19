use Test2::V0;
use File::Spec ();

use lib 't/lib';
use Test2::Harness2::TestFile;

subtest 'defaults fill in sensibly' => sub {
    my $tf = Test2::Harness2::TestFile->new(file => 't/foo.t');
    ok(File::Spec->file_name_is_absolute($tf->file), 'file made absolute');
    is($tf->relative,         't/foo.t', 'relative preserved as given');
    is($tf->min_slots,        1,         'min_slots defaults to 1');
    is($tf->max_slots,        undef,     'max_slots defaults to undef');
    is($tf->category,         'general', 'category default');
    is($tf->duration,         'medium',  'duration default');
    is([$tf->conflicts_list], [],        'no conflicts by default');
    ok(!$tf->has_conflicts, 'has_conflicts false by default');
    is($tf->features, {}, 'features empty');
    is($tf->switches, [], 'switches empty');
};

subtest 'accepts an absolute path' => sub {
    my $abs = File::Spec->rel2abs('t/foo.t');
    my $tf  = Test2::Harness2::TestFile->new(file => $abs);
    is($tf->file,     $abs,                      'abs path preserved');
    is($tf->absolute, $abs,                      'absolute matches');
    is($tf->relative, File::Spec->abs2rel($abs), 'relative derived');
};

subtest 'honours supplied attributes' => sub {
    my $tf = Test2::Harness2::TestFile->new(
        file      => 't/a.t',
        min_slots => 2,
        max_slots => 4,
        category  => 'isolation',
        duration  => 'long',
        conflicts => ['db', 'net'],
        features  => {fork => 0, preload => 1},
    );
    is($tf->min_slots,        2);
    is($tf->max_slots,        4);
    is($tf->category,         'isolation');
    is($tf->duration,         'long');
    is([$tf->conflicts_list], ['db', 'net']);
    ok($tf->has_conflicts, 'has conflicts');
    is($tf->feature('fork'),    0,     'feature fork=0');
    is($tf->feature('preload'), 1,     'feature preload=1');
    is($tf->feature('nope'),    undef, 'missing feature is undef');
};

subtest 'file is required' => sub {
    my $ok  = eval { Test2::Harness2::TestFile->new; 1 };
    my $err = $@;
    ok(!$ok, 'croaks without file');
    like($err, qr/file/);
};

subtest 'consumes the TestFile role' => sub {
    require Role::Tiny;
    my $tf = Test2::Harness2::TestFile->new(file => 't/foo.t');
    ok(
        Role::Tiny::does_role($tf, 'Test2::Harness2::Role::TestFile'),
        'TestFile consumes Role::TestFile'
    );
};

subtest 'TO_JSON round-trips through rehydrate' => sub {
    my $tf = Test2::Harness2::TestFile->new(
        file      => '/abs/t/foo.t',
        min_slots => 3,
        category  => 'immiscible',
        conflicts => ['db'],
        features  => {preload => 1},
    );
    my $json = $tf->TO_JSON;

    is($json->{file},      '/abs/t/foo.t', 'file round-trips');
    is($json->{min_slots}, 3,              'min_slots round-trips');
    is($json->{category},  'immiscible',   'category round-trips');
    is($json->{conflicts}, ['db'],         'conflicts round-trips');
    is($json->{features},  {preload => 1}, 'features round-trips');
    is($json->{absolute},  '/abs/t/foo.t', 'absolute emitted for downstream readers');
    is(
        $json->{__test_file_class__},
        'Test2::Harness2::TestFile',
        'class tag emitted for rehydrate',
    );

    my $rebuilt = Test2::Harness2::TestFile->rehydrate($json);
    isa_ok($rebuilt, ['Test2::Harness2::TestFile'], 'rebuilt is the same class');
    is($rebuilt->min_slots, 3,            'rehydrate preserves min_slots');
    is($rebuilt->category,  'immiscible', 'rehydrate preserves category');
    is($rebuilt->conflicts, ['db'],       'rehydrate preserves conflicts');
};

done_testing;
