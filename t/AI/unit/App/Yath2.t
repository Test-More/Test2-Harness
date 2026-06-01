use Test2::V0;
use v5.38;

use App::Yath2;

# App::Yath2 is the lightweight dispatcher: argv[0] selects the command.

sub run_app (@args) {
    my ($out, $err) = ('', '');
    my $exit;
    {
        open(my $o, '>', \$out) or die $!;
        open(my $e, '>', \$err) or die $!;
        local *STDOUT = $o;
        local *STDERR = $e;
        $exit = App::Yath2->new(args => [@args])->run;
    }
    return ($exit, $out, $err);
}

subtest no_command_shows_usage => sub {
    my ($exit, $out) = run_app();
    is($exit, 0, "no command exits 0");
    like($out, qr/Usage: yath/, "prints usage");
    like($out, qr/\btest\b/, "lists the test command");
};

subtest help => sub {
    my ($exit, $out) = run_app('help');
    is($exit, 0, "help exits 0");
    like($out, qr/Usage: yath/, "help prints usage");
};

subtest unknown_command => sub {
    my ($exit, $out, $err) = run_app('frobnicate');
    is($exit, 1, "unknown command exits 1");
    like($err, qr/Unknown command: frobnicate/, "names the bad command on STDERR");
};

done_testing;
