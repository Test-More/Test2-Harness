# NAME

Test2::Harness::Renderer::JUnit - Captures Test2::Harness results and emits a junit xml file.

# SYNOPSIS

On the command line, with `yath`:

    JUNIT_TEST_FILE="/tmp/test-output.xml" ALLOW_PASSING_TODOS=1 yath test --renderer=Formatter --renderer=JUnit -j4 t/*.t

# DESCRIPTION

`Test2::Harness::Renderer::JUnit` provides JUnit output formatting sufficient
to be parsed by Jenkins and hopefully other junit parsers.

This code borrows many ideas from `TAP::Formatter::JUnit` but unlike that module
does not provide a method to emit a different xml file for every testcase.
Instead, it defaults to emitting to a single **junit.xml** to whatever the directory
was you were in when you ran yath. This can be overridden by setting the
`JUNIT_TEST_FILE` environment variable

Timing information is included in the JUnit XML since this is native to `Test2::Harness`

In standard use, "passing TODOs" are treated as failure conditions (and are
reported as such in the generated JUnit).  If you wish to treat these as a
"pass" and not a "fail" condition, setting `ALLOW_PASSING_TODOS=1` in your
environment will turn these into pass conditions.

The JUnit output generated was developed to be used by Jenkins
([https://jenkins.io/](https://jenkins.io/)).  That's the build tool we use at the
moment and needed to be able to generate JUnit output for.

# METHODS

- **render\_event($event)**

    This is the only method (other than finish) that is called by Test2::Harness in order to
    gather the data needed to emit the needed xml.

- **close\_open\_failure\_testcase($test, $new\_test\_number)**

    This method is called whenever a new test result or the end of a run is seen. Because
    we want to capture test diag messages after a failed test, we delay emitting a failure
    until we see the end of the testcase or until we see a new test number.

- **finish()**

    This method is called by Test2::Harness when all runs are complete. It takes what has
    been gathered to that point and creates the junit xml file.

- xml

    An `XML::Generator` instance, to be used to generate XML output.

- init

    This subroutine is called during object initialization for Test2::Hanress objects.
    We do basic setup here.

# SOURCE

The source code repository for Test2-Harness-Renderer-JUnit can be found at
`https://github.com/CpanelInc/Test2-Harness-Renderer-JUnit`.

# MAINTAINERS

- Todd Rinaldo Todd Rinaldo, `<toddr at cpanel.net>`

# AUTHORS

- Todd Rinaldo, `<toddr at cpanel.net>`

# COPYRIGHT

Copyright 2019 Todd Rinaldo&lt;lt>toddr@cpanel.net>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See `http://dev.perl.org/licenses/`
