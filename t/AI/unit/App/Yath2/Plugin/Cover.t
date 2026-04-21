use Test2::V0;

use App::Yath2::Plugin::Cover;

subtest 'role composition' => sub {
    ok(App::Yath2::Plugin::Cover->DOES('App::Yath2::Role::Plugin'),
        'Cover consumes App::Yath2::Role::Plugin');
    ok(App::Yath2::Plugin::Cover->DOES('Test2::Harness2::Role::Plugin'),
        'Cover also satisfies Test2::Harness2::Role::Plugin transitively');
};

subtest 'HAS_* constant' => sub {
    ok(defined &App::Yath2::Plugin::Cover::HAS_TEST2_PLUGIN_COVER,
        'HAS_TEST2_PLUGIN_COVER constant exists');
};

subtest 'run_queued returns nothing in Stage 15' => sub {
    my $p = App::Yath2::Plugin::Cover->new();
    my @out = $p->run_queued({});
    is(scalar(@out), 0, 'no fields until aggregator returns in Stage 18');
};

subtest 'annotate_event short-circuits without aggregator' => sub {
    my $p = App::Yath2::Plugin::Cover->new();

    my @out = $p->annotate_event({facet_data => {coverage => {}}});
    is(scalar(@out), 0, 'no annotations without aggregator');

    # Flag set so subsequent calls also no-op fast.
    ok($p->{no_aggregate}, 'no_aggregate sticky flag set');
};

subtest 'client_finalize no-ops when nothing configured' => sub {
    my $p = App::Yath2::Plugin::Cover->new();

    my $captured = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$captured or die;
        $p->client_finalize(settings => fake_settings({}));
    }

    is($captured, '', 'no output when no coverage options are active');
};

subtest '_percentages helper' => sub {
    my $p = App::Yath2::Plugin::Cover->new();

    my $out = $p->_percentages({
        subs      => {total => 10, tested => 5},
        files     => {total => 4,  tested => 4},
        untested  => [qw/some_untested_thing/],
    });

    is(scalar(@$out), 2, 'two metrics (untested is filtered out)');

    my %by_name = map { $_->[0] => $_ } @$out;
    is($by_name{subs}->[3],  '50%',  'subs -> 50%');
    is($by_name{files}->[3], '100%', 'files -> 100%');
};

sub fake_settings {
    my ($cover) = @_;
    # A minimal duck-typed settings object whose ->cover returns a
    # structure the plugin expects. `check_group('cover')` returns
    # true so the finalize doesn't short-circuit on group check.
    my $obj = bless {cover => $cover}, 'Test::FakeSettings';
    return $obj;
}

done_testing;

package Test::FakeSettings;

sub check_group { 1 }
sub cover       { Test::FakeCover->new($_[0]->{cover}) }

package Test::FakeCover;

sub new {
    my ($class, $h) = @_;
    bless $h // {}, $class;
}
sub write   { $_[0]->{write} }
sub metrics { $_[0]->{metrics} }
