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

subtest 'defaults lists every documented attribute with a default' => sub {
    my $d = Test2::Harness2::Role::TestFile->defaults;
    is($d->{min_slots},         1,         'min_slots => 1');
    is($d->{max_slots},         undef,     'max_slots => undef');
    is($d->{category},          'general', 'category => general');
    is($d->{duration},          'medium',  'duration => medium');
    is($d->{stage},             undef,     'stage => undef');
    is($d->{conflicts},         [],        'conflicts => []');
    is($d->{smoke},             0,         'smoke => 0');
    is($d->{isolation},         0,         'isolation => 0');
    is($d->{retry},             0,         'retry => 0');
    is($d->{retry_isolated},    0,         'retry_isolated => 0');
    is($d->{non_perl},          0,         'non_perl => 0');
    is($d->{is_binary},         0,         'is_binary => 0');
    is($d->{switches},          [],        'switches => []');
    is($d->{features},          {},        'features => {}');
    is($d->{meta},              {},        'meta => {}');
    is($d->{ch_dir},            undef,     'ch_dir => undef');
    is($d->{event_timeout},     undef,     'event_timeout => undef');
    is($d->{post_exit_timeout}, undef,     'post_exit_timeout => undef');
    is($d->{comment},           '#',       'comment => #');
    ok(!exists $d->{file}, 'file has no default (required)');
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

subtest 'TO_JSON uses json_fields' => sub {
    my $tf = T::Role::TestFile::Closure->new(
        file      => '/abs/t/a.t',
        min_slots => 2,
        conflicts => ['db'],
        features  => {preload => 1},
    );
    my $json = $tf->TO_JSON;
    is($json->{file},      '/abs/t/a.t',   'file emitted');
    is($json->{min_slots}, 2,              'min_slots emitted');
    is($json->{conflicts}, ['db'],         'conflicts emitted');
    is($json->{features},  {preload => 1}, 'features emitted');
    ok(!exists $json->{absolute}, 'derived absolute is not emitted');
    ok(!exists $json->{relative}, 'derived relative is not emitted');
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
    is([sort keys %$json], [qw/file min_slots/], 'only overridden fields emitted');
};

done_testing;
