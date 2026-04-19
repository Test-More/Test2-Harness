use Test2::V0;

use Test2::Harness2::Role::TestFile;

# A storage-model-free consumer: one closure-backed accessor per required
# attribute. Proves the role doesn't touch $self as a hash.
{

    package T::Role::TestFile::Closure;
    use strict;
    use warnings;

    use Role::Tiny::With;

    sub new {
        my ($class, %attrs) = @_;
        my %store = %attrs;
        my $self  = bless sub { $store{$_[0]} }, $class;
        return $self;
    }

    for my $attr (qw{
        file
        min_slots max_slots
        category duration stage
        conflicts
        smoke isolation
        retry retry_isolated
        non_perl is_binary
        switches
        features meta
        ch_dir
        event_timeout post_exit_timeout
        comment
    })
    {
        no strict 'refs';
        *{"T::Role::TestFile::Closure::$attr"} = sub { $_[0]->($attr) };
    }

    with 'Test2::Harness2::Role::TestFile';
}

# Consumer with no HashBase shadowing; exercises the role's own default
# methods as the actual accessors.
{

    package T::Role::TestFile::Bare;
    use strict;
    use warnings;

    use Role::Tiny::With;

    sub new {
        my ($class, %attrs) = @_;
        return bless \%attrs, $class;
    }

    sub file { $_[0]->{file} }

    with 'Test2::Harness2::Role::TestFile';
}

subtest 'role provides per-attribute default methods' => sub {
    my $tf = T::Role::TestFile::Bare->new(file => '/x');
    is($tf->min_slots,         1,         'min_slots => 1');
    is($tf->max_slots,         undef,     'max_slots => undef');
    is($tf->category,          'general', 'category => general');
    is($tf->duration,          'medium',  'duration => medium');
    is($tf->stage,             undef,     'stage => undef');
    is($tf->conflicts,         [],        'conflicts => []');
    is($tf->smoke,             0,         'smoke => 0');
    is($tf->isolation,         0,         'isolation => 0');
    is($tf->retry,             0,         'retry => 0');
    is($tf->retry_isolated,    0,         'retry_isolated => 0');
    is($tf->non_perl,          0,         'non_perl => 0');
    is($tf->is_binary,         0,         'is_binary => 0');
    is($tf->switches,          [],        'switches => []');
    is($tf->features,          {},        'features => {}');
    is($tf->meta,              {},        'meta => {}');
    is($tf->ch_dir,            undef,     'ch_dir => undef');
    is($tf->event_timeout,     undef,     'event_timeout => undef');
    is($tf->post_exit_timeout, undef,     'post_exit_timeout => undef');
    is($tf->comment,           '#',       'comment => #');
};

subtest 'mutable defaults are fresh per call' => sub {
    my $tf = T::Role::TestFile::Bare->new(file => '/x');
    my $c1 = $tf->conflicts;
    my $c2 = $tf->conflicts;
    push @$c1 => 'x';
    is($c2, [], 'conflicts default arrayref is fresh per call');

    my $f1 = $tf->features;
    my $f2 = $tf->features;
    $f1->{k} = 1;
    is($f2, {}, 'features default hashref is fresh per call');
};

subtest 'default methods use accessors, not $self hash' => sub {
    my $tf = T::Role::TestFile::Closure->new(
        file      => '/abs/t/a.t',
        conflicts => ['db'],
        features  => {preload => 1},
    );

    is($tf->absolute, '/abs/t/a.t',                      'absolute via ->file');
    is($tf->relative, File::Spec->abs2rel('/abs/t/a.t'), 'relative via ->file');

    is($tf->feature('preload'), 1,     'feature via ->features');
    is($tf->feature('missing'), undef, 'feature returns undef when missing');
    is($tf->feature(undef),     undef, 'feature(undef) returns undef');

    is([$tf->conflicts_list], ['db'], 'conflicts_list returns a list');
    ok($tf->has_conflicts, 'has_conflicts true');
};

subtest 'conflicts_list tolerates undef conflicts' => sub {
    my $tf = T::Role::TestFile::Closure->new(file => '/x', conflicts => undef);
    is([$tf->conflicts_list], [], 'empty list when conflicts is undef');
    ok(!$tf->has_conflicts, 'has_conflicts false');
};

subtest 'TO_JSON uses json_fields and tags the class' => sub {
    my $tf = T::Role::TestFile::Closure->new(
        file      => '/abs/t/a.t',
        min_slots => 2,
        conflicts => ['db'],
        features  => {preload => 1},
    );
    my $json = $tf->TO_JSON;
    is($json->{file},      '/abs/t/a.t',                      'file emitted');
    is($json->{min_slots}, 2,                                 'min_slots emitted');
    is($json->{conflicts}, ['db'],                            'conflicts emitted');
    is($json->{features},  {preload => 1},                    'features emitted');
    is($json->{absolute},  '/abs/t/a.t',                      'derived absolute is emitted for downstream readers');
    is($json->{relative},  File::Spec->abs2rel('/abs/t/a.t'), 'derived relative is emitted');
    is(
        $json->{__test_file_class__},
        'T::Role::TestFile::Closure',
        'class tag emitted for rehydrate',
    );
};

subtest 'json_fields is overridable' => sub {
    {

        package T::Role::TestFile::Sub;
        use strict;
        use warnings;

        our @ISA = ('T::Role::TestFile::Closure');

        sub json_fields { qw/file min_slots/ }
    }

    my $tf   = T::Role::TestFile::Sub->new(file => '/x', min_slots => 4, conflicts => ['db']);
    my $json = $tf->TO_JSON;
    is(
        [sort keys %$json],
        [sort qw/file min_slots __test_file_class__/],
        'only overridden fields (plus class tag) emitted',
    );
};

subtest 'rehydrate: class is taken from the data, absolute/relative pass through' => sub {
    # Use a hash-backed consumer so the role's default rehydrate can
    # call $class->new with the unpacked hash.
    {

        package T::Role::TestFile::Hashy;
        use strict;
        use warnings;

        use Object::HashBase qw{
            <file
            <min_slots <max_slots
            <category <duration <stage
            <conflicts
            <smoke <isolation
            <retry <retry_isolated
            <non_perl <is_binary
            <switches
            <features <meta
            <ch_dir
            <event_timeout <post_exit_timeout
            <comment
        };
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::TestFile';
    }

    my $tf   = T::Role::TestFile::Hashy->new(file => '/abs/x.t', min_slots => 3);
    my $json = $tf->TO_JSON;

    # Invocant ignored: the class comes from __test_file_class__ in
    # the data. Call as a function:
    my $rebuilt = Test2::Harness2::Role::TestFile::rehydrate($json);
    isa_ok($rebuilt, ['T::Role::TestFile::Hashy'], 'rebuilt from the data-encoded class');
    is($rebuilt->file,      '/abs/x.t', 'file round-trips');
    is($rebuilt->min_slots, 3,          'min_slots round-trips');

    # absolute and relative are passed through to new() even though
    # the consumer doesn't store them -- classes that override can
    # treat them as authoritative.
    is($rebuilt->{absolute}, '/abs/x.t', 'absolute passed through to constructor args');
    ok(defined $rebuilt->{relative}, 'relative passed through to constructor args');

    # The class tag is consumed; it does not leak into the
    # constructor args.
    ok(!exists $rebuilt->{__test_file_class__}, '__test_file_class__ tag stripped before new');

    # As a class-method call, the invocant is ignored and the class
    # in the data wins.
    my $rebuilt2 = T::Role::TestFile::Hashy->rehydrate($json);
    isa_ok(
        $rebuilt2, ['T::Role::TestFile::Hashy'],
        'class-method form uses the data-encoded class'
    );

    my $missing = {file => '/x'};
    like(
        dies { Test2::Harness2::Role::TestFile::rehydrate($missing) },
        qr/No rehydration class was present/,
        'dies cleanly when class tag is missing',
    );

    like(
        dies { Test2::Harness2::Role::TestFile::rehydrate([]) },
        qr/hashref/,
        'dies cleanly on a non-hashref arg',
    );
};

done_testing;
