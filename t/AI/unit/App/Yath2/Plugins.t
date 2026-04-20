use Test2::V0;

use App::Yath2::Plugins;

# A stateless plugin: no new(), so the loader keeps the class name as
# the handle and dispatch is via class methods.
package App::Yath2::Plugin::Stateless;
use strict;
use warnings;
use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';

our @SEEN;
sub client_setup { push @SEEN => ['Stateless::client_setup', \@_]; return }
sub changed_files { return ('stateless.pm') }
$INC{'App/Yath2/Plugin/Stateless.pm'} = __FILE__;

# A stateful plugin: defines new(), gets instantiated with its args.
package App::Yath2::Plugin::Stateful;
use strict;
use warnings;
use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';

sub new {
    my ($class, @args) = @_;
    return bless { args => [@args] }, $class;
}
sub args { $_[0]->{args} }
sub client_setup { push @App::Yath2::Plugin::Stateless::SEEN => ['Stateful::client_setup', $_[0]->args]; return }
sub changed_files { return ('stateful.pm') }
$INC{'App/Yath2/Plugin/Stateful.pm'} = __FILE__;

package main;

subtest 'empty spec returns empty arrayref' => sub {
    my $plugins = App::Yath2::Plugins->load_plugins({});
    is($plugins, [], 'no plugins => empty arrayref');
};

subtest 'undef spec treated as empty' => sub {
    my $plugins = App::Yath2::Plugins->load_plugins();
    is($plugins, [], 'no arg => empty arrayref');
};

subtest 'non-hash spec croaks' => sub {
    my $ok  = eval { App::Yath2::Plugins->load_plugins([]); 1 };
    my $err = $@;
    ok(!$ok, 'arrayref input croaks');
    like($err, qr/must be a hashref/, 'error message mentions hashref');
};

subtest 'stateless plugin stays a class' => sub {
    my $plugins = App::Yath2::Plugins->load_plugins({
        'App::Yath2::Plugin::Stateless' => [],
    });
    is(scalar(@$plugins), 1, 'one plugin');
    is(ref($plugins->[0]), '', 'no new() => plugin is the class name, unblessed');
    is($plugins->[0], 'App::Yath2::Plugin::Stateless', 'class name preserved');
};

subtest 'stateful plugin is instantiated with its args' => sub {
    my $plugins = App::Yath2::Plugins->load_plugins({
        'App::Yath2::Plugin::Stateful' => ['a', 'b'],
    });
    is(scalar(@$plugins), 1, 'one plugin');
    ok(ref($plugins->[0]), 'has new() => is an instance');
    isa_ok($plugins->[0], ['App::Yath2::Plugin::Stateful'], 'right class');
    is($plugins->[0]->args, ['a', 'b'], 'constructor args preserved');
};

subtest 'args on a class-only plugin croak' => sub {
    my $ok = eval {
        App::Yath2::Plugins->load_plugins({
            'App::Yath2::Plugin::Stateless' => ['x'],
        });
        1;
    };
    my $err = $@;
    ok(!$ok, 'class-only plugin + args croaks');
    like($err, qr/no new/, 'error mentions missing new()');
};

subtest 'non-arrayref args croak' => sub {
    my $ok = eval {
        App::Yath2::Plugins->load_plugins({
            'App::Yath2::Plugin::Stateful' => 'scalar-args',
        });
        1;
    };
    my $err = $@;
    ok(!$ok, 'non-arrayref args croaks');
    like($err, qr/arrayref/, 'error mentions arrayref');
};

subtest 'missing plugin class produces a clear error' => sub {
    my $ok = eval {
        App::Yath2::Plugins->load_plugins({
            'App::Yath2::Plugin::DefinitelyNotInstalled' => [],
        });
        1;
    };
    my $err = $@;
    ok(!$ok, 'require-failure croaks');
    like($err, qr/Failed to load plugin/, 'error mentions plugin load failure');
};

subtest 'dispatch skips plugins without the hook' => sub {
    # Plugin without a 'missing_hook' method => skipped.
    my $plugins = App::Yath2::Plugins->load_plugins({
        'App::Yath2::Plugin::Stateless' => [],
        'App::Yath2::Plugin::Stateful'  => ['x'],
    });

    my @out = App::Yath2::Plugins->dispatch($plugins, 'missing_hook');
    is(\@out, [], 'no plugin has the hook => empty result');

    # Both plugins define changed_files; dispatch should collect them
    # in the order sort_keys produced (Stateful, Stateless).
    my @changed = App::Yath2::Plugins->dispatch($plugins, 'changed_files');
    is(\@changed, ['stateful.pm', 'stateless.pm'],
        'changed_files collected from every plugin that implements it');
};

subtest 'dispatch forwards args and collects returns in order' => sub {
    @App::Yath2::Plugin::Stateless::SEEN = ();
    my $plugins = App::Yath2::Plugins->load_plugins({
        'App::Yath2::Plugin::Stateful'  => ['arg'],
        'App::Yath2::Plugin::Stateless' => [],
    });
    App::Yath2::Plugins->dispatch($plugins, 'client_setup', extra => 'E');

    my @names = map { $_->[0] } @App::Yath2::Plugin::Stateless::SEEN;
    is(\@names, ['Stateful::client_setup', 'Stateless::client_setup'],
        'dispatch hits both plugins in order');
};

done_testing;
