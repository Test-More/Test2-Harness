use Test2::V0 -target => 'App::Yath::Plugin::SysInfo';
use Test2::Util qw/CAN_THREAD CAN_REALLY_FORK CAN_FORK CAN_SIGSYS/;
# HARNESS-DURATION-SHORT

my $control = mock $CLASS => (
    override => [
        hostname  => sub { 'foo.bar.baz-22.superlongnamewedonotwantseen.evenlonger.holycow.net' },
    ],
);

local %App::Yath::Plugin::SysInfo::Config = (
    'useperlio'       => 'define',
    'use64bitint'     => 'define',
    'use64bitall'     => 'define',
    'useithreads'     => 'define',
    'osname'          => 'linux',
    'archname'        => 'x86_64-linux',
    'usemultiplicity' => undef,
    'version'         => '1.2.3',
    'uselongdouble'   => undef,
);

local $ENV{USER} = 'bob';
local $ENV{SHELL} = '/bin/shell';
local $ENV{TERM} = 'myterm';

my $meta = {};
my $fields = [];

my $one = $CLASS->new();
$one->inject_run_data(meta => $meta, fields => $fields);

is(
    $fields,
    [
        {
            name    => 'sys',
            details => 'foo.bar.baz-22',
            raw     => 'foo.bar.baz-22.superlongnamewedonotwantseen.evenlonger.holycow.net',

            data => {
                hostname => 'foo.bar.baz-22.superlongnamewedonotwantseen.evenlonger.holycow.net',
                ipc      => {
                    can_fork        => CAN_FORK(),
                    can_really_fork => CAN_REALLY_FORK(),
                    can_sigsys      => CAN_SIGSYS(),
                    can_thread      => CAN_THREAD(),
                },
                env => {
                    shell => '/bin/shell',
                    term  => 'myterm',
                    user  => 'bob',
                },
                config => {
                    archname        => 'x86_64-linux',
                    osname          => 'linux',
                    use64bitall     => 'define',
                    use64bitint     => 'define',
                    useithreads     => 'define',
                    uselongdouble   => undef,
                    usemultiplicity => undef,
                    useperlio       => 'define',
                    version         => '1.2.3',
                }
            },
        }

    ],
    "Got expected fields"
);

$meta = {};
$fields = [];
$one = $CLASS->new(host_short_pattern => "bar\\.baz-\\d+");
$one->inject_run_data(meta => $meta, fields => $fields);

is(
    $fields,
    [
        {
            name    => 'sys',
            details => 'bar.baz-22',
            raw     => 'foo.bar.baz-22.superlongnamewedonotwantseen.evenlonger.holycow.net',

            data => {
                hostname => 'foo.bar.baz-22.superlongnamewedonotwantseen.evenlonger.holycow.net',
                ipc      => {
                    can_fork        => CAN_FORK(),
                    can_really_fork => CAN_REALLY_FORK(),
                    can_sigsys      => CAN_SIGSYS(),
                    can_thread      => CAN_THREAD(),
                },
                env => {
                    shell => '/bin/shell',
                    term  => 'myterm',
                    user  => 'bob',
                },
                config => {
                    archname        => 'x86_64-linux',
                    osname          => 'linux',
                    use64bitall     => 'define',
                    use64bitint     => 'define',
                    useithreads     => 'define',
                    uselongdouble   => undef,
                    usemultiplicity => undef,
                    useperlio       => 'define',
                    version         => '1.2.3',
                }
            },
        }

    ],
    "Got expected fields, including custom hostname short filter"
);

done_testing;
