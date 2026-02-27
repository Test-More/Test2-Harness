use Test2::V0 -target => 'App::Yath::Command::help';

use Getopt::Yath::Settings;

subtest 'run() returns 0 and produces command listing' => sub {
    my $settings = Getopt::Yath::Settings->new({
        help => { verbose => 0 },
        yath => { script => 'yath' },
    });

    my $obj = CLASS->new(
        settings => $settings,
        args     => [],
    );

    my $ret;
    my $stdout = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$stdout) or die $!;
        $ret = $obj->run();
    }

    is($ret, 0, 'run() returns 0');
    like($stdout, qr/Usage:/, 'output includes Usage line');
    like($stdout, qr/COMMANDS:/i, 'output includes COMMANDS section');
    like($stdout, qr/help/, 'output lists the help command itself');
};

subtest 'command_table returns formatted string' => sub {
    my $settings = Getopt::Yath::Settings->new({
        help => { verbose => 0 },
        yath => { script => 'yath' },
    });

    my $obj = CLASS->new(
        settings => $settings,
        args     => [],
    );

    my $table = $obj->command_table;
    ok(defined $table, 'command_table returns a value');
    like($table, qr/COMMANDS:/i, 'table contains COMMANDS heading');
};

done_testing;
