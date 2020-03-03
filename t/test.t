use Test2::V0;

use FindBin;

use File::Temp ();
use File::Spec;

use App::Yath::Tester qw/yath/;

use Test2::Harness::Util::File::JSONL ();
use Test2::Harness::Renderer::JUnit   ();

use Test2::Harness::Util qw/clean_path/;
use Test2::Harness::Util::JSON qw/decode_json/;

#use Test2::Bundle::Extended;
use Test2::Tools::Explain;
use Test2::Plugin::NoWarnings;

use XML::Simple ();

my $tmpdir = File::Temp->newdir();

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my @renderers = qw{--renderer=Formatter --renderer=JUnit};

delete $ENV{JUNIT_TEST_FILE};    # make sure it's not defined

my $env = {                      # env passed to yath
    PERL5LIB => "$FindBin::Bin/../lib",
};

{
    note "all tests are ok - JUNIT_TEST_FILE not set ; renderer define";

    my $sdir = $dir . '-ok';
    delete $env->{JUNIT_TEST_FILE};

    my $default_junit_xml = "$FindBin::Bin/../junit.xml";

    unlink $default_junit_xml if -e $default_junit_xml;

    yath(
        command => 'test',
        args    => [ $sdir, '--ext=tx', @renderers, '-v' ],
        exit    => 0,
        env     => $env,
        test    => sub {
            my $out = shift;

            like(
                $out->{output},
                qr{\Q( PASSED )\E.*\Qt/test-ok/pass-1.tx\E},
                "t/test-ok/pass-1.tx"
            );
            like(
                $out->{output},
                qr{\Q( PASSED )\E.*\Qt/test-ok/pass-2.tx\E},
                "t/test-ok/pass-2.tx"
            );

            like( $out->{output}, qr/Result: PASSED/, "Result: PASSED" );
        },
    );

    ok -e $default_junit_xml, "use default junit.xml location";

    unlink $default_junit_xml if -e $default_junit_xml;

}

{
    note
        "all tests are ok - JUNIT_TEST_FILE not reachable - No such file or directory";

    my $sdir = $dir . '-ok';

    $env->{JUNIT_TEST_FILE} = "$tmpdir/x/y/z/ok.xml";

    yath(
        command => 'test',
        args    => [ $sdir, '--ext=tx', @renderers, '-v' ],
        exit    => T(),
        env     => $env,
        test    => sub {
            my $out = shift;

            like(
                $out->{output},
                qr{\Q( PASSED )\E.*\Qt/test-ok/pass-1.tx\E},
                "t/test-ok/pass-1.tx"
            );
            like(
                $out->{output},
                qr{\Q( PASSED )\E.*\Qt/test-ok/pass-2.tx\E},
                "t/test-ok/pass-2.tx"
            );

            like(
                $out->{output}, qr{\QNo such file or directory\E},
                "No such file or directory."
            );
        },
    );

}

{
    note "all tests are ok";

    my $sdir = $dir . '-ok';

    $env->{JUNIT_TEST_FILE} = "$tmpdir/ok.xml";

    yath(
        command => 'test',
        args    => [ $sdir, '--ext=tx', @renderers, '-v' ],
        exit    => 0,
        env     => $env,
        test    => sub {
            my $out = shift;

            like(
                $out->{output},
                qr{\Q( PASSED )\E.*\Qt/test-ok/pass-1.tx\E},
                "t/test-ok/pass-1.tx"
            );
            like(
                $out->{output},
                qr{\Q( PASSED )\E.*\Qt/test-ok/pass-2.tx\E},
                "t/test-ok/pass-2.tx"
            );

            like( $out->{output}, qr/Result: PASSED/, "Result: PASSED" );
        },
    );

    # checking xml file
    ok -e $env->{JUNIT_TEST_FILE}, 'junit file exists';

    my $junit = XML::Simple::XMLin( $env->{JUNIT_TEST_FILE} );
    like $junit => hash {
        field testsuite => hash {
            field 'test-ok_pass-1_tx' => hash {
                field errors   => 0;
                field failures => 0;
                field id       => D();

                field 'system-err' => hash { end; };
                field 'system-out' => hash { end; };

                field 'testcase' => hash {
                    field '0001 - pass' => hash {
                        field classname => 'test-ok_pass-1_tx';
                        field time      => D();
                        end;
                    };
                    field 'Tear down.' => hash {
                        field classname => 'test-ok_pass-1_tx';
                        field time      => D();
                        end;
                    };

                    end;
                };

                field tests     => 1;
                field time      => D();
                field timestamp => D();

                end;
            };

            field 'test-ok_pass-2_tx' => hash {
                field errors   => 0;
                field failures => 0;
                field id       => D();

                field 'system-err' => hash { end; };
                field 'system-out' => hash { end; };

                field 'testcase' => hash {
                    field '0001 - pass' => hash {
                        field classname => 'test-ok_pass-2_tx';
                        field time      => D();
                        end;
                    };
                    field 'Tear down.' => hash {
                        field classname => 'test-ok_pass-2_tx';
                        field time      => D();
                        end;
                    };

                    end;
                };

                field tests     => 1;
                field time      => D();
                field timestamp => D();

                end;
            };

            end;
        };

        end;

    }, 'junit output' or diag explain $junit;
}

{
    note "plan ok - one failure";

    my $sdir = $dir . '-fail';

    $env->{JUNIT_TEST_FILE} = "$tmpdir/failure.xml";

    yath(
        command => 'test',
        args    => [ $sdir, '--ext=tx', @renderers, '-v' ],
        exit    => T(),
        env     => $env,
        test    => sub {
            my $out = shift;

            like(
                $out->{output},
                qr{\Q( FAILED )\E.*\Qt/test-fail/fail.tx\E},
                "t/test-fail/fail.tx"
            );

            like( $out->{output}, qr/Result: FAILED/, "Result: FAILED" );
        },
    );

    ok -e $env->{JUNIT_TEST_FILE}, 'junit file exists';

    my $junit = XML::Simple::XMLin( $env->{JUNIT_TEST_FILE} );

    like $junit => hash {
        field testsuite => hash {
            field errors   => 1;
            field failures => 1;
            field id       => D();
            field name     => 'test-fail_fail_tx';

            field 'system-err' => hash { end; };
            field 'system-out' => hash { end; };

            field 'testcase' => hash {
                field '0001 - pass' => hash {
                    field classname => 'test-fail_fail_tx';
                    field time      => D();
                    end;
                };
                field '0002 - this is a failure' => hash {
                    field classname => 'test-fail_fail_tx';
                    field time      => D();
                    field failure   => hash {
                        field content => match
                            qr{not ok 0002 - this is a failure};
                        field message => 'not ok 0002 - this is a failure';
                        field type    => 'TestFailed';
                    };
                    end;
                };
                field 'Tear down.' => hash {
                    field classname => 'test-fail_fail_tx';
                    field time      => D();
                    end;
                };

                end;
            };

            field tests     => 2;
            field time      => D();
            field timestamp => D();

            end;
        };

        end;

    }, 'junit output' or diag explain $junit;

}

{
    note "plan failure - test exit 0";

    my $sdir = $dir . '-plan';

    $env->{JUNIT_TEST_FILE} = "$tmpdir/plan.xml";

    yath(
        command => 'test',
        args    => [ $sdir, '--ext=tx', @renderers, '-v' ],
        exit    => T(),
        env     => $env,
        test    => sub {
            my $out = shift;

            like(
                $out->{output},
                qr{\Q( FAILED )\E.*\Qt/test-plan/plan.tx\E},
                "t/test-plan/plan.tx"
            );

            like( $out->{output}, qr/Result: FAILED/, "Result: FAILED" );
        },
    );

    ok -e $env->{JUNIT_TEST_FILE}, 'junit file exists';

    my $junit = XML::Simple::XMLin( $env->{JUNIT_TEST_FILE} );

    like $junit => hash {
        field testsuite => hash {
            field errors   => 2;
            field failures => 0;
            field id       => D();
            field name     => 'test-plan_plan_tx';

            field 'system-err' => hash { end; };
            field 'system-out' => hash { end; };

            field 'testcase' => hash {
                field '0001 - pass' => hash {
                    field classname => 'test-plan_plan_tx';
                    field time      => D();
                    end;
                };
                field '0002 - another success' => hash {
                    field classname => 'test-plan_plan_tx';
                    field time      => D();
                    end;
                };
                field 'Tear down.' => hash {
                    field classname => 'test-plan_plan_tx';
                    field time      => D();
                    end;
                };

                field 'Test Plan Failure' => hash {
                    field classname => 'test-plan_plan_tx';
                    field time      => D();
                    field failure   => match
                        q[Planned for 4 assertions, but saw 2];
                    end;
                };

                end;
            };

            field tests     => 2;
            field time      => D();
            field timestamp => D();

            end;
        };

        end;

    }, 'junit output' or diag explain $junit;

}

{
    note "plan ok - test exit non 0";

    my $sdir = $dir . '-die';

    $env->{JUNIT_TEST_FILE} = "$tmpdir/die.xml";

    yath(
        command => 'test',
        args    => [ $sdir, '--ext=tx', @renderers, '-v' ],
        exit    => T(),
        env     => $env,
        test    => sub {
            my $out = shift;

            like(
                $out->{output},
                qr{\Q( FAILED )\E.*\Qt/test-die/die.tx\E},
                "t/test-die/die.tx"
            );

            like( $out->{output}, qr/Result: FAILED/, "Result: FAILED" );
        },
    );

    ok -e $env->{JUNIT_TEST_FILE}, 'junit file exists';

    my $junit = XML::Simple::XMLin( $env->{JUNIT_TEST_FILE} );
    like $junit => hash {
        field testsuite => hash {
            field errors   => 1;
            field failures => 0;
            field id       => D();
            field name     => 'test-die_die_tx';

            field 'system-err' => hash { end; };
            field 'system-out' => hash { end; };

            field 'testcase' => hash {
                field '0001 - pass' => hash {
                    field classname => 'test-die_die_tx';
                    field time      => D();
                    end;
                };
                field '0002 - another success' => hash {
                    field classname => 'test-die_die_tx';
                    field time      => D();
                    end;
                };
                field 'Tear down.' => hash {
                    field classname => 'test-die_die_tx';
                    field time      => D();
                    end;
                };

                field 'Program Ended Unexpectedly' => hash {
                    field classname => 'test-die_die_tx';
                    field time      => D();
                    field failure   => match q[Test script returned error];
                    end;
                };

                end;
            };

            field tests     => 2;
            field time      => D();
            field timestamp => D();

            end;
        };

        end;

    }, 'junit output' or diag explain $junit;

}

{
    note "retry test - all succeed";

    my $sdir = $dir . '-retry';

    $env->{JUNIT_TEST_FILE} = "$tmpdir/retry.xml";
    $env->{FAIL_ONCE}       = 1;

    yath(
        command => 'test',
        args    => [ $sdir, '--ext=tx', @renderers, '-v', '--retry=1', ],
        exit    => 0,
        env     => $env,
        test    => sub {
            my $out = shift;

            like( $out->{output}, qr{FAIL.*Should fail once}, "one failure" );
            like(
                $out->{output},
                qr{\Q(TO RETRY)\E.*\Qt/test-retry/retry.tx\E},
                "TO RETRY t/test-retry/retry.tx"
            );
            like(
                $out->{output},
                qr{\Q( PASSED )\E.*\Qt/test-retry/retry.tx\E},
                "PASSED t/test-retry/retry.tx"
            );

            like( $out->{output}, qr/Result: PASSED/, "Result: PASSED" );
        },
    );

    my $junit = XML::Simple::XMLin( $env->{JUNIT_TEST_FILE} );
    like $junit => hash {
        field testsuite => hash {
            field errors   => 0;
            field failures => 0;
            field id       => D();
            field name     => 'test-retry_retry_tx';

            field 'system-err' => hash { end; };
            field 'system-out' => hash { end; };

            field 'testcase' => hash {
                field '0001 - Minimal result' => hash {
                    field classname => 'test-retry_retry_tx';
                    field time      => D();
                    end;
                };
                field 'Tear down.' => hash {
                    field classname => 'test-retry_retry_tx';
                    field time      => D();
                    end;
                };
                end;
            };

            field tests     => 1;
            field time      => D();
            field timestamp => D();

            end;
        };

        end;

    }, 'junit output' or diag explain $junit;

}

done_testing;
