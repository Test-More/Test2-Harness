use Test2::V0;
use v5.38;

use File::Temp ();

use Test2::API qw/run_subtest intercept/;
use Test2::Formatter::Stream2::IOEvents::Tie;

use constant TIE => 'Test2::Formatter::Stream2::IOEvents::Tie';

# The tie handler decides per-print whether to convert the output into a Test2
# info event (only inside a subtest) or pass it through to the real handle.
# _build constructs the handler object without actually tie()ing a glob, so the
# guard can be exercised directly.

sub handler { Test2::Formatter::Stream2::IOEvents::Tie->_build($_[0] // 'STDOUT') }

# NB: a Test2::V0 `subtest` is itself nested, so the top-level (nested == 0)
# check must run at real file scope, not inside one.
ok(!handler()->_should_convert, "no conversion at the top level (nested == 0)");

subtest converts_inside_a_subtest => sub {
    my $tie = handler();
    my $inside;
    run_subtest('probe', sub { $inside = $tie->_should_convert; ok(1, "probe ran") }, {buffered => 1});
    ok($inside, "conversion active inside a subtest (nested > 0)");
};

subtest reentrancy_guard => sub {
    my $tie = handler();
    run_subtest('probe', sub {
        local $tie->{+Test2::Formatter::Stream2::IOEvents::Tie::ACTIVE()} = 1;
        ok(!$tie->_should_convert, "no conversion while a conversion is already active");
    }, {buffered => 1});
};

subtest fork_guard => sub {
    my $tie = handler();
    run_subtest('probe', sub {
        local $tie->{+Test2::Formatter::Stream2::IOEvents::Tie::PID()} = $$ - 1;
        ok(!$tie->_should_convert, "no conversion when the pid changed (a fork)");
    }, {buffered => 1});
};

# Find the info facets emitted (via context) for text we printed. Buffered
# subtests fold their events into parent.children, so recurse into those too.
sub collect_info ($facets, $out) {
    push @$out => @{$facets->{info}} if $facets->{info};
    collect_info($_, $out) for @{$facets->{parent}{children} // []};
}

sub printed_info ($events) {
    my @info;
    collect_info($_->facet_data, \@info) for @$events;
    return @info;
}

subtest print_inside_subtest_emits_info => sub {
    my $events = intercept {
        run_subtest('p', sub {
            TIE->_build('STDOUT')->PRINT("hello\n");
            ok(1, "ran");
        }, {buffered => 1});
    };

    my ($info) = grep { ($_->{details} // '') eq "hello\n" } printed_info($events);
    ok($info, "STDOUT print became an info event");
    is($info->{tag}, 'STDOUT', "tagged STDOUT");
    ok(!$info->{debug}, "STDOUT info is not debug");
};

subtest stderr_print_is_debug => sub {
    my $events = intercept {
        run_subtest('p', sub {
            TIE->_build('STDERR')->PRINT("oops\n");
            ok(1, "ran");
        }, {buffered => 1});
    };

    my ($info) = grep { ($_->{details} // '') eq "oops\n" } printed_info($events);
    ok($info, "STDERR print became an info event");
    is($info->{tag}, 'STDERR', "tagged STDERR");
    ok($info->{debug}, "STDERR info is marked debug");
};

subtest printf_formats => sub {
    my $events = intercept {
        run_subtest('p', sub {
            TIE->_build('STDOUT')->PRINTF("%s=%d\n", "x", 7);
            ok(1, "ran");
        }, {buffered => 1});
    };
    my ($info) = grep { ($_->{details} // '') eq "x=7\n" } printed_info($events);
    ok($info, "PRINTF formatted then emitted as info");
};

subtest passes_through_when_not_converting => sub {
    my $tie = handler('STDOUT');

    # Force the non-converting path (pid guard) and redirect the passthrough
    # target to an in-memory buffer so we can see what was written.
    $tie->{+TIE->PID} = $$ - 1;
    open(my $buf_fh, '>', \my $buf) or die "open buffer: $!";
    $tie->{+TIE->REAL_FH} = $buf_fh;

    $tie->PRINT("raw-passthrough\n");
    is($buf, "raw-passthrough\n", "print written to the real handle, not converted");
};

subtest write_passes_through_to_real_handle => sub {
    # syswrite needs a real fd (not an in-memory scalar handle), so use a file.
    my $tmp = File::Temp->new;
    my $tie = handler('STDOUT');
    open(my $real, '>&', $tmp) or die "dup tmp: $!";
    $tie->{+TIE->REAL_FH} = $real;

    $tie->WRITE("abcdef", 3, 0);
    close($real);
    open(my $in, '<', "$tmp") or die "reopen: $!";
    is(scalar(readline($in)), "abc", "WRITE forwards to the real handle via syswrite");
};

subtest fileno_reports_real_descriptor => sub {
    my $tie = handler('STDOUT');
    is($tie->FILENO, $tie->{+TIE->FD}, "FILENO returns the real descriptor number");
};

subtest binmode_does_not_die => sub {
    my $tie = handler('STDOUT');
    open(my $buf_fh, '>', \my $buf) or die "open buffer: $!";
    $tie->{+TIE->REAL_FH} = $buf_fh;
    ok(lives { $tie->BINMODE(':raw') }, "BINMODE applies to the real handle without dying");
};

done_testing;
