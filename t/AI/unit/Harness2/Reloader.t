use Test2::V0;

use File::Temp qw/tempdir/;

use Test2::Harness2::Reloader::Default;
use Test2::Harness2::Reloader::KillRestart;

subtest 'KillRestart always refuses' => sub {
    my $r = Test2::Harness2::Reloader::KillRestart->new;

    ok($r->viable, 'kill-restart is always viable');

    my ($status, %fields) = $r->reload_module('Foo::Bar', '/tmp/foo.pm', {});
    is($status, 'not_reloadable', 'kill-restart returns not_reloadable');
    like($fields{reason}, qr/KillRestart/, 'reason mentions KillRestart policy');
};

subtest 'Default refuses non-perl files without callback' => sub {
    my $r = Test2::Harness2::Reloader::Default->new;
    my ($status, %fields) = $r->reload_module(undef, '/tmp/data.yaml', {perl => 0});
    is($status, 'not_reloadable', 'non-perl without callback is not_reloadable');
    like($fields{reason}, qr/non-perl/, 'reason mentions non-perl');
};

subtest 'Default refuses modules with non-trivial import' => sub {
    my $r = Test2::Harness2::Reloader::Default->new;
    my ($status, %fields) = $r->reload_module(
        'Foo::Bar',
        '/tmp/foo.pm',
        {perl => 1, has_import => 1},
    );
    is($status, 'not_reloadable', 'import() module is not_reloadable');
    like($fields{reason}, qr/non-trivial import/, 'reason mentions import');
};

subtest 'Default routes user watch callback' => sub {
    my $r = Test2::Harness2::Reloader::Default->new;

    my @seen;
    my $cb = sub { push @seen => [@_]; return (1) };

    my ($status) = $r->reload_module('Foo::Bar', '/tmp/foo.pm', {callback => $cb});
    is($status,     1,             'user callback controls reload status');
    is($seen[0][0], '/tmp/foo.pm', 'callback got the file path');
};

subtest 'Default reloads a real pure-perl module in place' => sub {
    my $dir = tempdir(CLEANUP => 1);
    local @INC = ($dir, @INC);

    my $modfile = "$dir/ReloadTargetAI.pm";
    open(my $fh, '>', $modfile) or die $!;
    print $fh <<'PERL';
package ReloadTargetAI;
our $VALUE = 'v1';
1;
PERL
    close($fh);

    require ReloadTargetAI;

    # Use symbolic stash lookup so we see the post-reload glob. The
    # direct C<$Pkg::VALUE> form binds at compile time to the original
    # glob's SV slot, which deleted-and-re-created stash entries don't
    # update. Symbolic deref resolves at runtime against whatever glob
    # currently occupies the stash -- that's what in-process consumers
    # (preload stage launch paths) will effectively be doing.
    my $read = sub { no strict 'refs'; ${"ReloadTargetAI::VALUE"} };
    is($read->(), 'v1', 'v1 loaded');

    # Rewrite the module in place.
    open(my $fh2, '>', $modfile) or die $!;
    print $fh2 <<'PERL';
package ReloadTargetAI;
our $VALUE = 'v2';
1;
PERL
    close($fh2);

    my $r = Test2::Harness2::Reloader::Default->new;
    my ($status, %fields) = $r->reload_module(
        'ReloadTargetAI',
        $modfile,
        {perl => 1, has_import => 0, module => 'ReloadTargetAI', inc_entry => 'ReloadTargetAI.pm'},
    );
    is($status,   1,    'in-place reload succeeded') or diag(explain(\%fields));
    is($read->(), 'v2', 'VALUE bumped after reload');
};

done_testing;
