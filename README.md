# NAME

Test2::Harness2 - Top-level test harness service.

# SYNOPSIS

    # Run once, then exit
    Test2::Harness2->start(
        workdir                  => '/path/to/wd',
        test_run                 => {files => ['t/a.t', 't/b.t']},
        finish_after_initial_run => 1,
    );

    # Spawn as a persistent daemon, keep queuing
    my $spawn = Test2::Harness2->spawn(workdir => '/path/to/wd');
    $spawn->queue_test_run(files => ['t/c.t']);
    my $status = $spawn->status;
    $spawn->finish;
    $spawn->wait;

# DESCRIPTION

**Use start() or spawn(), not new().** Direct `new()` constructs the object
but does not start the service loop. Prefer the `start()` entry point when
you want the current process to become the harness, or `spawn()` when you
want the harness to run in a child process and get back a handle to it.

# JUMP\_TO

Passing `jump_to => $name` to `start()` tells the harness to unwind
its own call stack inside the interposed collector child before running the
service, using [Long::Jump](https://metacpan.org/pod/Long%3A%3AJump). The caller must install a matching
`setjump()` around the `start()` call; when the longjump fires the
setjump returns a single-element arrayref whose only element is a
coderef. Invoking that coderef runs the service (set up the emitter, queue
any requested run, enter the main loop, and `_exit`).

This is useful when a test script has deep harness machinery above the
setjump that should not be present on the service's stack. After the jump,
the service runs from a clean stack frame, so exceptions and stack traces
are tidier and an accidental `return` out of the service cannot resume
execution anywhere unintended.

    use Long::Jump qw/setjump/;

    my $ret = setjump 'harness' => sub {
        Test2::Harness2->start(
            workdir => $wd,
            jump_to => 'harness',
            # ... other start() args ...
        );
        # unreachable in the service child; the parent becomes the
        # collector and exits without returning here either.
    };

    my ($run_service) = @$ret;
    $run_service->();   # never returns; service calls _exit

If `jump_to` is set but no matching setjump is active, `start()` croaks
before forking. Without `jump_to`, `start()` behaves exactly as before.

# SOURCE

The source code repository for Test2-Harness can be found at
[https://github.com/Test-More/Test2-Harness](https://github.com/Test-More/Test2-Harness).

# MAINTAINERS

- Chad Granum <exodist@cpan.org>

# AUTHORS

- Chad Granum <exodist@cpan.org>

# COPYRIGHT

Copyright Chad Granum <exodist7@gmail.com>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See [https://dev.perl.org/licenses/](https://dev.perl.org/licenses/)
