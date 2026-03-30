use Test2::V0;

# Test2::Formatter::Stream imports Test2::Harness::Collector::Child at compile
# time, which requires the process to be running inside a yath collector.  When
# loaded outside that context it dies with "We do not appear to be inside a
# collector".  Skip gracefully in that case.
eval { require Test2::Formatter::Stream; 1 }
    or skip_all "Test2::Formatter::Stream requires a collector context: $@";

our $CLASS = 'Test2::Formatter::Stream';

# --- Inheritance ---

isa_ok($CLASS, ['Test2::Formatter'], "inherits from Test2::Formatter");

# --- Interface ---

can_ok($CLASS, qw/
    init record encoding write
    hide_buffered handles
    set_no_header set_no_diag set_no_numbers set_handles
    terminate finalize
/);

# --- hide_buffered class method ---

ok(!$CLASS->hide_buffered, "hide_buffered() returns false");

done_testing;
