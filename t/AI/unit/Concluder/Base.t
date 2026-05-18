use strict;
use warnings;

use Test2::V0;

use App::Yath2::Concluder;

# A bare Concluder constructed against a placeholder log object: we
# only exercise the base contract here.
my $fake_log = bless {}, 'T::FakeLog';

subtest 'log is required' => sub {
    like(
        dies { App::Yath2::Concluder->new() },
        qr/'log' is required/,
        'missing log croaks',
    );
};

subtest 'out_fh defaults to STDOUT' => sub {
    my $c = App::Yath2::Concluder->new(log => $fake_log);
    is($c->out_fh, \*STDOUT, 'default out_fh is STDOUT');
};

subtest 'explicit out_fh round-trips' => sub {
    open my $fh, '>', \my $buf or die "open scalar: $!";
    my $c = App::Yath2::Concluder->new(log => $fake_log, out_fh => $fh);
    is($c->out_fh, $fh, 'explicit out_fh stored');
};

subtest 'settings round-trips' => sub {
    my $s = bless {}, 'T::FakeSettings';
    my $c = App::Yath2::Concluder->new(log => $fake_log, settings => $s);
    is($c->settings, $s, 'settings stored');
};

subtest 'base run croaks' => sub {
    my $c = App::Yath2::Concluder->new(log => $fake_log);
    like(
        dies { $c->run },
        qr/must implement run/,
        'base run croaks',
    );
};

subtest 'async defaults to 0' => sub {
    my $c = App::Yath2::Concluder->new(log => $fake_log);
    is($c->async, 0, 'async defaults to 0');
};

done_testing;
