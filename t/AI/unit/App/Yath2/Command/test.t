use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use App::Yath2::Command::test;

# Exercise the Stage 6 priority-option wiring as unit tests so we can
# verify the plumbing without depending on the harness launch path
# (which has a pre-existing Stage 5 regression — see PLAN_RESUME).
#
# The private helpers live as module-level subs so we can call them
# directly here; the command's run() wires them together but is
# integration-tested elsewhere once the harness launch is fixed.

my $parse_helper    = \&App::Yath2::Command::test::_parse_argv;
my $includes_helper = \&App::Yath2::Command::test::_build_launch_args;
my $slots_helper    = \&App::Yath2::Command::test::_resolve_slots;
my $verbose_helper  = \&App::Yath2::Command::test::_resolve_verbose;
my $preloads_helper = \&App::Yath2::Command::test::_resolve_preloads;

sub parse { $parse_helper->([@_]) }

# Run from a clean empty tempdir so the lib/blib auto-include probe is
# deterministic (no accidental positives from the project's own lib/).
my $tmp  = tempdir(CLEANUP => 1);
my $orig = do { my $c; chomp($c = `pwd`); $c };
chdir $tmp or die "chdir '$tmp': $!";

subtest '-I paths flow through as -I<path> switches' => sub {
    my $parsed = parse('-I', '/a', '-I', '/b', 'ignored.t');
    my $la = $includes_helper->($parsed->{settings}, $parsed);
    is($la, ['-I/a', '-I/b'], '-I paths collected in order');
};

subtest '--lib adds -Ilib regardless of whether lib/ exists' => sub {
    my $parsed = parse('-l', 't/foo.t');
    my $la = $includes_helper->($parsed->{settings}, $parsed);
    is($la, ['-Ilib'], '--lib -> -Ilib');
};

subtest '--blib adds -Iblib/lib -Iblib/arch' => sub {
    my $parsed = parse('-b', 't/foo.t');
    my $la = $includes_helper->($parsed->{settings}, $parsed);
    is($la, ['-Iblib/lib', '-Iblib/arch'], '--blib -> blib/lib + blib/arch');
};

subtest 'no flags and no local lib/ -> empty launch_args' => sub {
    my $parsed = parse('t/foo.t');
    my $la = $includes_helper->($parsed->{settings}, $parsed);
    is($la, [], 'nothing to inject when the cwd has no lib/ and no blib/');
};

subtest 'no flags with local lib/ -> auto -Ilib' => sub {
    mkdir 'lib' or die "mkdir lib: $!";
    my $parsed = parse('t/foo.t');
    my $la = $includes_helper->($parsed->{settings}, $parsed);
    is($la, ['-Ilib'], 'lib/ auto-included when cwd has lib/');
    rmdir 'lib';
};

subtest '--no-lib suppresses auto -Ilib' => sub {
    mkdir 'lib' or die "mkdir lib: $!";
    my $parsed = parse('--no-lib', 't/foo.t');
    my $la = $includes_helper->($parsed->{settings}, $parsed);
    is($la, [], '--no-lib wins over the auto-include heuristic');
    rmdir 'lib';
};

subtest '-I and -l combine in order' => sub {
    my $parsed = parse('-I', '/ext', '-l', 't/foo.t');
    my $la = $includes_helper->($parsed->{settings}, $parsed);
    is($la, ['-I/ext', '-Ilib'], '-I values come before --lib');
};

subtest '--slots / --job-count / -j set resource slot count' => sub {
    for my $args ([qw/-j 8/], [qw/--slots 8/], [qw/--job-count 8/]) {
        my $parsed = parse(@$args, 't/foo.t');
        is($slots_helper->($parsed->{settings}), 8, "@$args -> 8 slots");
    }
};

subtest 'slots default is a sensible positive integer when not specified' => sub {
    # The actual default comes from App::Yath2::Options::Resource's
    # option definition (half the CPU cores via System::Info, falling
    # back to 2). We only check that the helper returns something
    # positive because the exact value depends on the host.
    my $parsed = parse('t/foo.t');
    my $slots  = $slots_helper->($parsed->{settings});
    ok(defined $slots && $slots =~ m/^\d+$/ && $slots > 0,
        "default slots ($slots) is a positive integer");
};

subtest 'slots falls back to 1 for malformed values' => sub {
    # Construct a settings object directly with a bogus 'slots' value to
    # exercise the helper's defensive clause (Getopt::Yath's Scalar
    # type does not validate, so the command has to).
    {
        package Test::Fake::Resource;
        sub new { my ($c, %h) = @_; bless { %h } => $c }
        sub slots { $_[0]->{slots} }
    }
    {
        package Test::Fake::Settings;
        sub new { my ($c, %h) = @_; bless { %h } => $c }
        sub resource { $_[0]->{resource} }
    }

    for my $bad (0, -1, 'not-a-number', undef, '') {
        my $settings = Test::Fake::Settings->new(
            resource => Test::Fake::Resource->new(slots => $bad),
        );
        my $label = defined $bad && length $bad ? $bad : '(empty)';
        is($slots_helper->($settings), 1, "slots='$label' -> 1");
    }
};

subtest '--verbose counts and records a level' => sub {
    my $p0  = parse('t/foo.t');
    my $p1  = parse('-v', 't/foo.t');
    my $p2  = parse('-vv', 't/foo.t');
    is($verbose_helper->($p0->{settings}),  0, 'no -v -> 0');
    is($verbose_helper->($p1->{settings}),  1, '-v -> 1');
    is($verbose_helper->($p2->{settings}),  2, '-vv -> 2');
};

subtest '--preload / -P records values (placeholder -- ignored at runtime)' => sub {
    my $parsed = parse('--preload', 'Foo', '-P', 'Bar', 't/foo.t');
    my $p = $preloads_helper->($parsed->{settings});
    is([sort @$p], ['Bar', 'Foo'], 'both forms captured');
};

subtest 'positional args survive option parsing' => sub {
    my $parsed = parse('-j', '4', '-v', 't/a.t', 't/b.t');
    my @positional = @{$parsed->{skipped} // []};
    push @positional => @{$parsed->{remains}} if $parsed->{remains};
    is([sort @positional], ['t/a.t', 't/b.t'], 'positional args preserved');
};

my $mode_helper      = \&App::Yath2::Command::test::_resolve_mode;
my $renderers_helper = \&App::Yath2::Command::test::_load_renderers;

subtest 'mode resolution' => sub {
    is($mode_helper->(parse('t/foo.t')->{settings}),                    'default', 'no flags -> default');
    is($mode_helper->(parse('-v',    't/foo.t')->{settings}),           'verbose', '-v -> verbose');
    is($mode_helper->(parse('--quiet',     't/foo.t')->{settings}),     'quiet',   '--quiet -> quiet');
    is($mode_helper->(parse('--qvf',       't/foo.t')->{settings}),     'qvf',     '--qvf -> qvf');
    # qvf wins if both are set
    is($mode_helper->(parse('--qvf', '-v', 't/foo.t')->{settings}),     'qvf',     'qvf wins over verbose');
};

subtest 'renderer-class resolution' => sub {
    # Default set: Default + Summary
    my $parsed    = parse('t/foo.t');
    my $renderers = $renderers_helper->($parsed->{settings});
    ok(ref($renderers) eq 'ARRAY', 'returns arrayref');
    ok(scalar(@$renderers) >= 2, 'default set has at least two renderers');
    my %seen = map { ref($_) => 1 } @$renderers;
    ok($seen{'App::Yath2::Renderer::Default'}, 'Default is in the default set');
    ok($seen{'App::Yath2::Renderer::Summary'}, 'Summary is in the default set');
};

subtest '--renderer adds a named renderer via the short prefix' => sub {
    my $parsed = parse('-r', 'Formatter', 't/foo.t');
    my $renderers = $renderers_helper->($parsed->{settings});
    my %seen = map { ref($_) => 1 } @$renderers;
    ok($seen{'App::Yath2::Renderer::Formatter'}, 'Formatter got loaded');
};

chdir $orig or die "chdir back to '$orig': $!";

done_testing;
