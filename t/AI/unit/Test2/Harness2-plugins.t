use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2;

# Stateless plugin consumed by the harness role.
package HarnessSidePlugin;
use Role::Tiny::With;
with 'Test2::Harness2::Role::Plugin';
sub new { bless {}, shift }

package main;

subtest 'plugins defaults to empty arrayref' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $h = Test2::Harness2->new(workdir => $tmp);
    is($h->plugins, [], 'plugins is [] by default');
};

subtest 'plugins preserves the caller-supplied list' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $p1 = HarnessSidePlugin->new;
    my $p2 = 'HarnessSidePlugin';    # class-as-plugin also allowed
    my $h  = Test2::Harness2->new(workdir => $tmp, plugins => [$p1, $p2]);
    is(scalar(@{ $h->plugins }), 2, 'both plugins retained');
    is($h->plugins->[0], $p1, 'instance preserved by ref identity');
    is($h->plugins->[1], $p2, 'class-name preserved');
};

subtest 'non-arrayref plugins croaks' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ok  = eval { Test2::Harness2->new(workdir => $tmp, plugins => 'nope'); 1 };
    my $err = $@;
    ok(!$ok, 'scalar plugins argument croaks');
    like($err, qr/arrayref/, 'error mentions arrayref');
};

done_testing;
