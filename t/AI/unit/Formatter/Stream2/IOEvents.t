use Test2::V0;
use v5.38;

use Test2::API qw/test2_list_pre_subtest_callbacks/;
use Test2::Formatter::Stream2::IOEvents;

use constant IOE => 'Test2::Formatter::Stream2::IOEvents';
use constant TIE => 'Test2::Formatter::Stream2::IOEvents::Tie';

subtest install_and_uninstall_ties => sub {
    ok(!tied(*STDOUT), "STDOUT not tied to begin with");

    IOE->_install_ties;
    isa_ok(tied(*STDOUT), [TIE], "STDOUT tied with our handler");
    isa_ok(tied(*STDERR), [TIE], "STDERR tied with our handler");

    # Idempotent: a second install does not replace the existing tie objects.
    my $out = tied(*STDOUT);
    IOE->_install_ties;
    is(tied(*STDOUT), $out, "second install keeps the same tie object");

    # Drop our reference before untie so it has no lingering inner refs.
    undef $out;
    IOE->_uninstall_ties;
    ok(!tied(*STDOUT), "STDOUT untied");
    ok(!tied(*STDERR), "STDERR untied");
};

subtest reinstalls_after_the_tie_is_lost => sub {
    IOE->_install_ties;
    isa_ok(tied(*STDOUT), [TIE], "tied to start");

    # Simulate a reopen (Capture::Tiny, open STDOUT, ...) that drops our tie.
    untie(*STDOUT);
    untie(*STDERR);
    ok(!tied(*STDOUT), "tie lost");

    # This is exactly what the pre_subtest hook runs at each subtest start.
    IOE->_install_ties;
    isa_ok(tied(*STDOUT), [TIE], "tie refreshed after loss");
    isa_ok(tied(*STDERR), [TIE], "STDERR tie refreshed after loss");

    IOE->_uninstall_ties;
};

subtest enable_registers_one_callback => sub {
    my $before = scalar test2_list_pre_subtest_callbacks();
    IOE->enable;
    IOE->enable;
    my $after = scalar test2_list_pre_subtest_callbacks();
    is($after - $before, 1, "enable registers exactly one pre_subtest callback, even called twice");
};

done_testing;
