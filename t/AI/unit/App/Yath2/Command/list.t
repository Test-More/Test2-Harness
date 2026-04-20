use Test2::V0;

use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempdir/;

use App::Yath2::Command::list;

# These subtests exercise return codes only; STDOUT / STDERR
# capture is intentionally skipped because Test2::Formatter's
# output handle and Perl's local *STDOUT don't play nicely
# together across subtest boundaries. Shell-level smoke coverage
# for the happy-path output lives in the Stage 13 STAGE_SUMMARY
# (see the `yath list` invocation there).

subtest 'construction basics' => sub {
    my $cmd = App::Yath2::Command::list->new(argv => ['x']);
    is($cmd->argv, ['x'], 'argv captured');
};

subtest 'no paths returns exit 2' => sub {
    my $cmd = App::Yath2::Command::list->new(argv => []);

    # Send our own error writes to /dev/null to keep the TAP stream
    # clean; we care about the return code, not the text.
    my $ec;
    {
        open(my $devnull, '>', File::Spec->devnull) or die $!;
        local *STDERR = $devnull;
        $ec = $cmd->run;
    }
    is($ec, 2, 'exit 2 on missing paths');
};

subtest 'invalid path returns exit 1 or croaks' => sub {
    my $cmd = App::Yath2::Command::list->new(argv => ['/no/such/path/exists/plz']);

    my $ec;
    {
        open(my $devnull, '>', File::Spec->devnull) or die $!;
        local *STDERR = $devnull;
        $ec = eval { $cmd->run };
    }

    # Finder::Simple croaks on a missing path; $ec is undef and $@
    # is a string. Accept either the croak path OR an explicit
    # exit-1 return; both are acceptable error behaviour.
    ok(!defined $ec || $ec == 1, 'error signalled')
        or diag("ec=$ec, err=$@");
};

done_testing;
