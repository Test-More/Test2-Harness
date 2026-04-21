use Test2::V0;

use App::Yath2::Options::Yath;

# Stage 6 activation check: -D / --help / --version (and the supporting
# --dev-libs-verbose) are declared on the 'yath' option group and are
# reachable via the module's parse_options closure.
#
# parse_options is a closure over the module's Getopt::Yath::Instance,
# so it has to be called via the module's symbol table (or from inside
# the module). We grab it by name here to exercise the options without
# needing to construct a command object or run the full dispatcher.

my $parse = \&App::Yath2::Options::Yath::parse_options;

sub parse_argv {
    my @argv = @_;
    return $parse->([@argv], skip_non_opts => 1, stops => ['--']);
}

subtest 'yath group defines dev_libs, dev_libs_verbose, help, version' => sub {
    my $parsed = parse_argv('--');
    my $yath   = $parsed->{settings}{yath};
    ok($yath, 'yath settings group exists');

    # Presence checks: each option must yield a (possibly falsy/empty)
    # value on the group. hash access bypasses AUTOLOAD, so a missing
    # key means the option definition did not land.
    ok(exists $yath->{dev_libs},         'dev_libs option is registered');
    ok(exists $yath->{dev_libs_verbose}, 'dev_libs_verbose option is registered');
    ok(exists $yath->{help},             'help option is registered');
    ok(exists $yath->{version},          'version option is registered');
};

subtest '--version / -V -> version => 1' => sub {
    for my $args (['--version'], ['-V']) {
        my $parsed = parse_argv(@$args, '--');
        is($parsed->{settings}{yath}{version}, 1, "@$args sets version");
    }
};

subtest '--help=GROUP / -h=GROUP -> help => GROUP' => sub {
    my $parsed = parse_argv('--help=yath', '--');
    is($parsed->{settings}{yath}{help}, 'yath', '--help=yath captured as scalar');
};

subtest '--help (no arg) triggers autofill' => sub {
    my $parsed = parse_argv('--help', '--');
    # Auto + autofill => 1 means the bare form sets the value to 1.
    is($parsed->{settings}{yath}{help}, 1, 'bare --help autofills to 1');
};

subtest '-D with a path already in @INC records it without re-exec' => sub {
    # 'lib' is literally in @INC (we loaded the module with -Ilib), so the
    # trigger's "missing from @INC" check short-circuits and no exec() runs.
    my $parsed = parse_argv('-Dlib', '--');
    my $list   = $parsed->{settings}{yath}{dev_libs};
    ok(ref($list) eq 'ARRAY' && @$list >= 1, '-Dlib recorded at least one path');
    ok((grep { m{(?:^|/)lib$} } @$list), 'resolved path ends in /lib');
};

subtest 'combined: -V --help=yath parses both' => sub {
    my $parsed = parse_argv('-V', '--help=yath', '--');
    my $yath   = $parsed->{settings}{yath};
    is($yath->{version}, 1,      'version recorded');
    is($yath->{help},    'yath', 'help recorded');
};

done_testing;
