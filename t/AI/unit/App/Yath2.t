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

subtest 'bare command name dispatches (stub) and exits 2' => sub {
    my $r = run_app(argv => ['test']);
    is($r->{exit}, 2, 'exit 2');
    like($r->{err}, qr/'test' command has not been ported/, 'stub banner on STDERR');
};

subtest '-D is stripped before command lookup' => sub {
    # -D on its own (no command) falls through to the usage banner.
    my $bare = run_app(argv => ['-D']);
    is($bare->{exit}, 0, '-D alone: exit 0');
    like($bare->{out}, qr/USAGE:/, '-D alone: usage printed');

    # -D <cmd> should route to the command, not be rejected as
    # a leftover option.
    my $with_cmd = run_app(argv => ['-D', 'test', 'foo.t']);
    is($with_cmd->{exit}, 2, '-D <cmd>: stub exit 2');
    like($with_cmd->{err}, qr/'test' command has not been ported/, '-D <cmd>: stub banner');

    # -D=lib <cmd> should also route to the command.
    my $with_arg = run_app(argv => ['-D=lib', 'test']);
    is($with_arg->{exit}, 2, '-D=lib <cmd>: stub exit 2');
    like($with_arg->{err}, qr/'test' command has not been ported/, '-D=lib <cmd>: stub banner');
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
