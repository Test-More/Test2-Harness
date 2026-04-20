use Test2::V0;

use App::Yath2::Command::test;

my $parse_helper   = \&App::Yath2::Command::test::_parse_argv;
my $loader_helper  = \&App::Yath2::Command::test::_load_plugins;

sub parse { $parse_helper->([@_]) }

# Inline plugin defs so we do not depend on any on-disk plugin file.
# Both roles are already loadable via the real lib/ tree.
package App::Yath2::Plugin::Demo;
use strict;
use warnings;
use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';
sub new {
    my ($class, @args) = @_;
    return bless { args => [@args] }, $class;
}
sub args { $_[0]->{args} }
$INC{'App/Yath2/Plugin/Demo.pm'} = __FILE__;

package App::Yath2::Plugin::NoCtor;
use strict;
use warnings;
use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';
$INC{'App/Yath2/Plugin/NoCtor.pm'} = __FILE__;

# A plugin in a different namespace, reachable via the '+' short-circuit.
package Other::NS::Plug;
use strict;
use warnings;
use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';
$INC{'Other/NS/Plug.pm'} = __FILE__;

package main;

subtest '-pDemo=a,b gets stored under $settings->yath->plugins' => sub {
    my $parsed = parse('-pDemo=a,b', 't/foo.t');
    my $map    = $parsed->{settings}->yath->plugins;
    is(
        $map,
        {'App::Yath2::Plugin::Demo' => ['a', 'b']},
        'short-form -p with comma args resolves the class and splits args',
    );
};

subtest '--plugin=NoCtor resolves to the class, no args' => sub {
    my $parsed = parse('--plugin=NoCtor', 't/bar.t');
    my $map    = $parsed->{settings}->yath->plugins;
    is(
        $map,
        {'App::Yath2::Plugin::NoCtor' => []},
        'long-form with no args yields empty arrayref',
    );
};

subtest 'multiple plugins from a single argv' => sub {
    my $parsed = parse('-pDemo=x', '-pNoCtor', 't/a.t');
    my $map    = $parsed->{settings}->yath->plugins;
    is(
        $map,
        {
            'App::Yath2::Plugin::Demo'   => ['x'],
            'App::Yath2::Plugin::NoCtor' => [],
        },
        'both entries land in the plugins map',
    );
};

subtest 'fully-qualified plugin name passes through as-is' => sub {
    my $parsed = parse('-p+Other::NS::Plug', 't/x.t');
    my $map    = $parsed->{settings}->yath->plugins;
    is(
        $map,
        {'Other::NS::Plug' => []},
        '+-prefix short-circuits the App::Yath2::Plugin auto-prefixing',
    );
};

subtest '_load_plugins instantiates the command-layer plugin list' => sub {
    my $parsed = parse('-pDemo=hello,world', '-pNoCtor', 't/x.t');
    my $plugins = $loader_helper->($parsed->{settings});

    is(scalar(@$plugins), 2, 'two plugins loaded');

    # sort order is stable (alphabetical) per App::Yath2::Plugins
    isa_ok($plugins->[0], ['App::Yath2::Plugin::Demo'], 'Demo is an instance');
    is($plugins->[0]->args, ['hello', 'world'], 'Demo got its args');
    is(ref($plugins->[1]), '', 'NoCtor stayed a class');
    is($plugins->[1], 'App::Yath2::Plugin::NoCtor', 'NoCtor class name preserved');
};

subtest 'parse with no --plugin yields an empty plugin set' => sub {
    my $parsed = parse('t/a.t');
    my $plugins = $loader_helper->($parsed->{settings});
    is($plugins, [], 'no plugin option => empty list');
};

done_testing;
