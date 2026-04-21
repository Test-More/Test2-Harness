use Test2::V0;

use App::Yath2;

# Helper: run App::Yath2 with @argv, capture STDOUT, STDERR, and the
# returned exit code. Uses in-memory filehandles so the tests don't
# leak output onto the runner's STDOUT.
sub run_app {
    my (%params) = @_;
    my $argv = $params{argv} // [];

    my $app = App::Yath2->new(
        script => $params{script} // 'yath',
        argv   => [@$argv],
    );

    my ($out, $err) = ('', '');
    my $exit;
    {
        open(my $ofh, '>', \$out) or die "open scalar stdout: $!";
        open(my $efh, '>', \$err) or die "open scalar stderr: $!";
        local *STDOUT = $ofh;
        local *STDERR = $efh;
        $exit = $app->run;
    }

    return {out => $out, err => $err, exit => $exit};
}

subtest 'no args prints usage and exits 0' => sub {
    my $r = run_app(argv => []);
    is($r->{exit}, 0, 'exit 0');
    like($r->{out}, qr/USAGE:/, 'usage banner on STDOUT');
    is($r->{err}, '', 'STDERR empty');
};

subtest '--version / -V print version and exit 0' => sub {
    for my $flag ('--version', '-V') {
        my $r = run_app(argv => [$flag]);
        is($r->{exit}, 0, "$flag: exit 0");
        like($r->{out}, qr/App::Yath2 \d+\.\d+/, "$flag: version banner on STDOUT");
        is($r->{err}, '', "$flag: STDERR empty");
    }
};

subtest '--help / -h print full help and exit 0' => sub {
    for my $flag ('--help', '-h') {
        my $r = run_app(argv => [$flag]);
        is($r->{exit}, 0, "$flag: exit 0");
        like($r->{out}, qr/USAGE:/,      "$flag: usage banner");
        like($r->{out}, qr/Yath Options/, "$flag: Yath Options section rendered");
        is($r->{err}, '', "$flag: STDERR empty");
    }
};

subtest '--help=GROUP renders group-scoped docs' => sub {
    my $r = run_app(argv => ['--help=yath']);
    is($r->{exit}, 0, 'exit 0');
    like($r->{out}, qr/Yath Options\s+\(yath\)/, 'group header present');
    like($r->{out}, qr/-D/,                      'dev-lib option documented');
    like($r->{out}, qr/--help/,                  'help option documented');
    is($r->{err}, '', 'STDERR empty');
};

subtest '--help=BAD-GROUP errors with exit 2' => sub {
    my $r = run_app(argv => ['--help=not-a-real-group']);
    is($r->{exit}, 2, 'exit 2');
    like($r->{err}, qr/unknown option group 'not-a-real-group'/, 'error on STDERR');
    like($r->{err}, qr/Known groups:/,                           'lists known groups');
};

subtest 'bare command name with no loadable class errors with exit 2' => sub {
    # Stage 4 ships no App::Yath2::Command::* classes, so any command
    # name resolves to 'unknown command'.
    my $r = run_app(argv => ['test']);
    is($r->{exit}, 2, 'exit 2');
    like($r->{err}, qr/unknown command 'test'/, 'unknown command banner on STDERR');
};

subtest '-D is stripped before command lookup' => sub {
    # -D on its own (no command) falls through to the usage banner.
    my $bare = run_app(argv => ['-D']);
    is($bare->{exit}, 0, '-D alone: exit 0');
    like($bare->{out}, qr/USAGE:/, '-D alone: usage printed');

    # -D <cmd> should route to the command, not be rejected as
    # a leftover option.
    my $with_cmd = run_app(argv => ['-D', 'test', 'foo.t']);
    is($with_cmd->{exit}, 2, '-D <cmd>: exit 2');
    like($with_cmd->{err}, qr/unknown command 'test'/, '-D <cmd>: unknown command banner');

    # -D=lib <cmd> should also route to the command.
    my $with_arg = run_app(argv => ['-D=lib', 'test']);
    is($with_arg->{exit}, 2, '-D=lib <cmd>: exit 2');
    like($with_arg->{err}, qr/unknown command 'test'/, '-D=lib <cmd>: unknown command banner');
};

subtest 'unknown top-level option errors with exit 2' => sub {
    my $r = run_app(argv => ['--no-such-option']);
    is($r->{exit}, 2, 'exit 2');
    like($r->{err}, qr/'--no-such-option' is not a valid yath option/, 'error on STDERR');
    like($r->{err}, qr/USAGE:/, 'usage printed on STDERR');
};

subtest 'unknown command errors with exit 2' => sub {
    my $r = run_app(argv => ['bogus']);
    is($r->{exit}, 2, 'exit 2');
    like($r->{err}, qr/unknown command 'bogus'/, 'error on STDERR');
    like($r->{err}, qr/USAGE:/,                  'usage printed on STDERR');
};

subtest 'help subcommand prints top-level usage (Stage 4 stub)' => sub {
    my $r = run_app(argv => ['help']);
    is($r->{exit}, 0, 'exit 0');
    like($r->{out}, qr/USAGE:/, 'usage banner');
};

subtest 'load_command rejects invalid / missing command names' => sub {
    my $app = App::Yath2->new(script => 'yath', argv => []);
    is($app->load_command(undef),      undef, 'undef name');
    is($app->load_command(''),         undef, 'empty name');
    is($app->load_command('9bad'),     undef, 'name starts with digit');
    is($app->load_command('bad-name'), undef, 'name with dash');
    is($app->load_command('foo::bar'), undef, 'name with :: (no path escape)');
    is($app->load_command('test'),     undef, 'no such class installed in Stage 4');
};

subtest 'load_command returns the class when the module loads' => sub {
    # Inject a fake App::Yath2::Command::fakeok via @INC coderef.
    # The returned "file" defines a package that subclasses
    # App::Yath2::Command, so load_command should return the class
    # name. An App::Yath2::Command base is provided here too because
    # Stage 4 does not yet ship one.
    # isa() only walks the @ISA chain; App::Yath2::Command does not
    # have to exist as a real module for the check to pass.
    my $hook = sub {
        my ($me, $file) = @_;
        return unless $file eq 'App/Yath2/Command/fakeok.pm';
        my $src = 'package App::Yath2::Command::fakeok;'
            . ' our @ISA = ("App::Yath2::Command"); 1;';
        open(my $fh, '<', \$src) or die "open scalar: $!";
        return $fh;
    };

    local @INC = ($hook, @INC);
    my $app = App::Yath2->new(script => 'yath', argv => []);
    is($app->load_command('fakeok'), 'App::Yath2::Command::fakeok', 'loads and returns class');
};

subtest 'loaded command falls through to the Stage 4 stub' => sub {
    # Same fake-class trick as above, but exercised through run():
    # the command class loads, so the dispatch branch prints the
    # 'dispatch not yet wired' banner instead of 'unknown command'.
    # isa() only walks the @ISA chain; App::Yath2::Command does not
    # have to exist as a real module for the check to pass.
    my $hook = sub {
        my ($me, $file) = @_;
        return unless $file eq 'App/Yath2/Command/fakeok.pm';
        my $src = 'package App::Yath2::Command::fakeok;'
            . ' our @ISA = ("App::Yath2::Command"); 1;';
        open(my $fh, '<', \$src) or die "open scalar: $!";
        return $fh;
    };

    local @INC = ($hook, @INC);
    my $r = run_app(argv => ['fakeok']);
    is($r->{exit}, 2, 'exit 2');
    like(
        $r->{err},
        qr/'fakeok' command resolved to App::Yath2::Command::fakeok/,
        'stage 4 dispatch stub banner'
    );
};

subtest 'argv is not mutated by run' => sub {
    my @orig = ('-D', 'test', 'foo.t');
    my $app  = App::Yath2->new(script => 'yath', argv => [@orig]);

    my ($out, $err) = ('', '');
    {
        open(my $ofh, '>', \$out) or die "open scalar stdout: $!";
        open(my $efh, '>', \$err) or die "open scalar stderr: $!";
        local *STDOUT = $ofh;
        local *STDERR = $efh;
        $app->run;
    }

    is($app->argv, \@orig, 'argv contents unchanged after run');
};

done_testing;
