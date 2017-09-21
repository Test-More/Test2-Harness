BEGIN { $ENV{T2_HARNESS_DEBUG} = 0 }
use Test2::V0 -target => 'Test2::Harness::Util::Debug';

use ok $CLASS => qw/DEBUG DEBUG_ON DEBUG_OFF/;

imported_ok qw/DEBUG DEBUG_ON DEBUG_OFF/;

my $stderr = "";

eval {
    local *STDERR;
    open(STDERR, '>', \$stderr) or die "Could not open new STDERR";

    DEBUG_OFF;

    DEBUG "Before\nActivation!";

    DEBUG_ON;

    DEBUG "After\nActivation!";

    DEBUG_OFF;

    DEBUG "After\nDeactivation!";

    kill('USR1', $$) or die "Could not send signal";

    DEBUG "After\nSignal\n";

    1;
} or die $@;

is($stderr, <<EOT, "Got expected debug output");
After
Activation!
SIGUSR1 Detected, turning on debugging...
After
Signal
EOT

done_testing;
