use Test2::V0;

use Test2::Harness2::Collector::Auditor::Test;
use Test2::Util::UUID qw/gen_uuid/;

my $CLASS = 'Test2::Harness2::Collector::Auditor::Test';

sub mk { $CLASS->new(ipcm_info => {}, run_id => 'R', job_id => 'J', job_try => 0, @_) }

subtest 'construction' => sub {
    my $a = $CLASS->new(ipcm_info => {});
    ok($a,                   "constructs without run_id/job_id/job_try");
    ok(!defined $a->run_id,  "run_id defaults to undef");
    ok(!defined $a->job_id,  "job_id defaults to undef");
    ok(!defined $a->job_try, "job_try defaults to undef");

    my $b = mk();
    is($b->run_id,          'R', "run_id stored");
    is($b->job_id,          'J', "job_id stored");
    is($b->job_try,         0,   "job_try stored");
    is($b->nested,          0,   "nested defaults to 0");
    is($b->assertion_count, 0,   "no assertions yet");

    ok($b->DOES('Test2::Harness2::Role::Auditor'), "consumes Role::Auditor");
};

subtest 'set_process_info' => sub {
    my $a = $CLASS->new(ipcm_info => {});
    $a->set_process_info(run_id => 'RR', job_id => 'JJ', job_try => 3);
    is($a->run_id,  'RR', "run_id updated via set_process_info");
    is($a->job_id,  'JJ', "job_id updated via set_process_info");
    is($a->job_try, 3,    "job_try updated via set_process_info");

    # Partial update -- only keys present in %info are changed.
    $a->set_process_info(job_try => 5);
    is($a->run_id,  'RR', "run_id unchanged after partial update");
    is($a->job_try, 5,    "job_try updated");
};

subtest 'set_ipcm_info' => sub {
    my $a  = $CLASS->new(ipcm_info => {});
    my $ii = {host => 'localhost'};
    $a->set_ipcm_info($ii);
    is($a->ipcm_info, $ii, "ipcm_info stored via set_ipcm_info");
};

subtest 'empty auditor state' => sub {
    my $a = mk();

    ok(!$a->has_exit, "no exit yet");
    ok(!$a->has_plan, "no plan yet");
    ok(!$a->failing,  "not failing on construction (no events processed)");
    ok($a->passing,   "passing on construction");
    is($a->fail_count, 0, "fail_count is 0");
    is($a->pass_count, 0, "pass_count is 0");

    # fail() consults fail_error_facet_list which complains about missing plan,
    # so it latches as failing once asked.
    ok($a->fail,  "fail() latches because empty test would fail at exit");
    ok(!$a->pass, "pass() agrees");
};

subtest 'passing assertion' => sub {
    my $a   = mk();
    my @out = $a->audit_event({facet_data => {assert => {pass => 1, details => 'ok'}}});

    is($a->assertion_count, 1, "assertion counted");
    is($a->pass_count,      1, "one passing assertion");
    is($a->fail_count,      0, "no failures");
    ok(!$a->failing, "still passing live");

    is(@out, 1, "one event returned");
    my $ev = $out[0];
    ok($ev->{event_id}, "event has event_id");
    ok(!exists $ev->{run_id},                      "run_id not stamped on event");
    ok(!exists $ev->{job_id},                      "job_id not stamped on event");
    ok(!exists $ev->{job_try},                     "job_try not stamped on event");
    ok(!exists $ev->{facet_data}{harness}{run_id}, "run_id not stamped on harness facet");
    ok(!exists $ev->{facet_data}{harness}{job_id}, "job_id not stamped on harness facet");
    ok(!exists $ev->{facet_data}{harness}{job_try}, "job_try not stamped on harness facet");
    is($ev->{facet_data}{harness}{event_id}, $ev->{event_id}, "event_id mirrored into harness facet");
    ok(!$ev->{facet_data}{about}, "about facet not autovivified when absent from input");
};

subtest 'failing assertion' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {assert => {pass => 0, details => 'nope'}}});

    is($a->assertion_count, 1, "assertion counted");
    is($a->pass_count,      0, "no passes");
    ok($a->failing,         "failing live");
    ok($a->fail_count >= 1, "fail_count >= 1");
};

subtest 'amnesty (todo) on failing assertion' => sub {
    my $a = mk();
    $a->audit_event({
        facet_data => {
            assert  => {pass => 0, details => 'todo failure'},
            amnesty => [{tag => 'TODO', details => 'reason'}],
        }
    });

    is($a->assertion_count, 1, "assertion counted");
    ok(!$a->failing, "todo failure does not count as failure");
};

subtest 'plan tracking' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {count => 3}}});
    ok($a->has_plan, "plan recorded");
    is($a->plan->{count}, 3, "plan count visible");

    # second plan -> too many plans
    $a->audit_event({facet_data => {plan => {count => 5}}});
    my @errs = $a->subtest_fail_error_facet_list;
    ok((grep { $_->{details} =~ /Too many plans/ } @errs), "too many plans flagged");
};

subtest 'plan with skip (no count)' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {none => 1, details => 'env not set'}}});
    ok(!$a->has_plan, "skip plans do not count toward has_plan");
};

subtest 'plan / assertion-count mismatch' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan   => {count => 3}}});
    $a->audit_event({facet_data => {assert => {pass  => 1}}});
    $a->audit_event({facet_data => {assert => {pass  => 1}}});

    my @errs = $a->subtest_fail_error_facet_list;
    ok(
        (grep { $_->{details} =~ /Planned for 3 assertions, but saw 2/ } @errs),
        "plan/count mismatch flagged"
    );
};

subtest 'no plan declared but assertions made' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {assert => {pass => 1}}});
    my @errs = $a->subtest_fail_error_facet_list;
    ok((grep { $_->{details} eq 'No plan was declared' } @errs), "no-plan-with-asserts flagged");
};

subtest 'bail-out / halt' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {control => {halt => 1, details => 'BAIL!'}}});
    is($a->halt, 'BAIL!', "halt details captured");
    ok($a->failing, "halt counts as failing");
};

subtest 'error facets' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {errors => [{tag => 'X', fail => 1, details => 'boom'}]}});
    ok($a->failing,         "errors facet with fail=>1 marks failing");
    ok($a->fail_count >= 1, "fail_count incremented");
};

subtest 'TAP assertion numbers' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {assert => {pass => 1, number => 1}}});
    $a->audit_event({facet_data => {assert => {pass => 1, number => 1}}});    # dup
    $a->audit_event({facet_data => {assert => {pass => 1, number => 3}}});    # skip 2

    my @errs = $a->subtest_fail_error_facet_list;
    ok(
        (grep { $_->{details} =~ /number 1 was seen more than once/ } @errs),
        "duplicate number flagged"
    );
    ok(
        (grep { $_->{details} =~ /number 2 was never seen/ } @errs),
        "missing number flagged"
    );
};

subtest 'harness_process_exit synthesizes harness_job_exit' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan   => {count => 1}}});
    $a->audit_event({facet_data => {assert => {pass  => 1}}});

    my @out = $a->audit_event({
        facet_data => {
            harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0},
        }
    });

    is(@out, 1, "exit produces one event");
    my $ev   = $out[0];
    my $exit = $ev->{facet_data}{harness_job_exit};

    ok($exit, "harness_job_exit synthesized");
    is($exit->{job_id},     'J', "job_id on harness_job_exit");
    is($exit->{job_try},    0,   "job_try on harness_job_exit");
    is($exit->{exit},       0,   "exit value on harness_job_exit");
    is($exit->{codes}{all}, 0,   "codes preserves parse_exit hash");
    ok(defined $exit->{stamp}, "stamp set");

    is($a->exit, 0, "auditor records exit code");
    ok($a->has_exit, "has_exit true");
};

subtest 'non-zero exit produces fail facets' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {count => 0}}});

    my @out = $a->audit_event({
        facet_data => {
            harness_process_exit => {all => 42 << 8, err => 42, sig => 0, dmp => 0},
        }
    });

    my $ev   = $out[0];
    my $errs = $ev->{facet_data}{errors};
    ok($errs && @$errs, "errors injected onto exit event");
    ok(
        (grep { $_->{details} =~ /returned error \(Err: 42\)/ } @$errs),
        "non-zero exit flagged in errors"
    );
};

subtest 'event_id is preserved when already set on event' => sub {
    my $a   = mk();
    my $eid = gen_uuid();
    my @out = $a->audit_event({event_id => $eid, facet_data => {assert => {pass => 1}}});
    is($out[0]->{event_id},                      $eid, "existing event_id preserved");
    is($out[0]->{facet_data}{harness}{event_id}, $eid, "harness.event_id mirrors");
    ok(!$out[0]->{facet_data}{about}, "about facet not autovivified");
};

subtest 'event_id mirrors into about.uuid when about facet is already present' => sub {
    my $a   = mk();
    my $eid = gen_uuid();
    my @out = $a->audit_event({
        event_id   => $eid,
        facet_data => {
            assert => {pass    => 1},
            about  => {details => 'something'},
        },
    });
    is($out[0]->{facet_data}{about}{uuid}, $eid,
        'about.uuid stamped when about facet was present');
};

subtest 'event_id sourced from facet_data.harness.event_id' => sub {
    my $a   = mk();
    my $eid = gen_uuid();
    my @out = $a->audit_event({
        facet_data => {
            assert  => {pass     => 1},
            harness => {event_id => $eid},
        }
    });
    is($out[0]->{event_id}, $eid, "event_id taken from harness facet");
};

subtest 'event_id sourced from facet_data.about.uuid' => sub {
    my $a   = mk();
    my $eid = gen_uuid();
    my @out = $a->audit_event({
        facet_data => {
            assert => {pass => 1},
            about  => {uuid => $eid},
        }
    });
    is($out[0]->{event_id}, $eid, "event_id taken from about.uuid");
};

subtest 'event_id generated when missing everywhere' => sub {
    my $a   = mk();
    my @out = $a->audit_event({facet_data => {assert => {pass => 1}}});
    like($out[0]->{event_id}, qr/^[0-9A-F-]{36}$/i, "uuid-shaped event_id generated");
};

subtest 'STDERR from_tap events bypass subtest processing' => sub {
    my $a   = mk();
    my @out = $a->audit_event({
        facet_data => {
            info     => [{tag => 'STDERR', details => 'some diag'}],
            from_tap => {source => 'STDERR', details => 'some diag'},
        }
    });
    is(@out,                1, "stderr passed through");
    is($a->assertion_count, 0, "no assertion counted");
};

subtest 'STDOUT line from_tap is processed' => sub {
    my $a   = mk();
    my @out = $a->audit_event({
        facet_data => {
            info     => [{tag => 'STDOUT', details => 'random text'}],
            from_tap => {source => 'STDOUT', details => 'random text'},
        }
    });
    is(@out, 1, "event passed through");
};

subtest 'subtest pass/fail accounting via parent.children' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {count => 1}}});
    $a->audit_event({
        facet_data => {
            assert => {pass => 1, details => 'inner subtest'},
            parent => {
                hid      => 1,
                children => [
                    do { my $id = gen_uuid(); {assert => {pass => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                    do { my $id = gen_uuid(); {plan => {count => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                ],
            },
        }
    });
    ok(!$a->failing, "passing subtest leaves auditor passing");
};

subtest 'subtest with internal failure marks parent failing' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {count => 1}}});
    # In a real event stream Test2 sets the outer subtest assert to pass=>0
    # whenever any inner assertion fails; the auditor relies on that signal.
    $a->audit_event({
        facet_data => {
            assert => {pass => 0, details => 'subtest'},
            parent => {
                hid      => 1,
                children => [
                    do { my $id = gen_uuid(); {assert => {pass => 0}, harness => {event_id => $id}, about => {uuid => $id}} },
                    do { my $id = gen_uuid(); {plan => {count => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                ],
            },
        }
    });
    ok($a->failing,             "subtest with failed inner assertion marks failing");
    ok($a->failed_subtest_tree, "failed_subtest_tree populated");
};

subtest 'subtest with internal plan-mismatch bubbles up' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {count => 1}}});
    # Outer assert says pass, but inner plan says 5 with only 1 assertion --
    # the sub-auditor should detect the mismatch and force the outer subtest
    # to fail via injected error facets.
    $a->audit_event({
        facet_data => {
            assert => {pass => 1, details => 'subtest'},
            parent => {
                hid      => 1,
                children => [
                    do { my $id = gen_uuid(); {assert => {pass => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                    do { my $id = gen_uuid(); {plan => {count => 5}, harness => {event_id => $id}, about => {uuid => $id}} },
                ],
            },
        }
    });
    ok($a->failing, "internal plan mismatch in subtest marks parent failing");
};

subtest 'pass/fail latching after exit' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan                 => {count => 1}}});
    $a->audit_event({facet_data => {assert               => {pass  => 1}}});
    $a->audit_event({facet_data => {harness_process_exit => {all   => 0, err => 0, sig => 0, dmp => 0}}});

    ok($a->pass,  "pass() true after clean exit");
    ok(!$a->fail, "fail() false after clean exit");
};

subtest 'ipcm_info is required at construction' => sub {
    my $ok  = eval { $CLASS->new(run_id => 'R', job_id => 'J', job_try => 0); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without ipcm_info');
    like($err, qr/ipcm_info/, 'error mentions ipcm_info');
};

subtest 'subtest_start emits a synthetic subtest_started announcement' => sub {
    my $a = mk();

    my @out = $a->audit_event({
        event_id   => 'ST-1',
        stamp      => 1234.5,
        facet_data => {
            harness => {subtest_start => 1, stamp => 1234.5, nested => 0},
            trace   => {frame => ['main', 't/foo.t', 42]},
        },
    });

    is(scalar @out, 1, 'one announcement event emitted');
    my $ann = $out[0];

    ok($ann->{facet_data}{harness}{subtest_started}, 'new subtest_started flag set');
    ok(!$ann->{facet_data}{harness}{subtest_start},  'raw subtest_start not re-emitted');
    is($ann->{facet_data}{harness}{nested}, 0, 'nested preserved');
    is($ann->{facet_data}{harness}{stamp},  1234.5, 'harness stamp preserved');
    is($ann->{stamp}, 1234.5, 'top-level stamp preserved');
    is($ann->{facet_data}{trace}{frame}, ['main', 't/foo.t', 42], 'trace preserved');
    isnt($ann->{event_id}, 'ST-1', 'announcement has its own event_id');

    # The original event is still stashed internally for subsequent
    # subtest-close processing.
    ok($a->subtests->{1}, 'subtest stashed internally');
};

subtest 'subtest_start does not announce when not at this auditor level' => sub {
    my $a = mk();

    # TAP-parsed nested subtest_start: from_tap is set and the effective
    # nesting (read from hub_truth, which uses hubs[0] or trace) is > 0.
    # The from_tap gate lets the event reach the subtest_start branch,
    # but the announcement must not fire because this is not the
    # auditor's own level.
    my @out = $a->audit_event({
        event_id   => 'ST-NESTED',
        facet_data => {
            harness  => {subtest_start => 1},
            from_tap => {source => 'STDOUT', details => 'ok 1 - sub {'},
            trace    => {frame => ['main', 't/foo.t', 10], nested => 1},
        },
    });

    ok(!grep({ $_->{facet_data}{harness}{subtest_started} } @out),
        'no subtest_started announcement emitted for nested level');
};

subtest 'auditor tracks passing and failing top-level subtest names' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {count => 2}}});

    # Passing subtest
    $a->audit_event({
        facet_data => {
            assert => {pass => 1, details => 'alpha'},
            parent => {
                hid      => 1,
                children => [
                    do { my $id = gen_uuid(); {assert => {pass => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                    do { my $id = gen_uuid(); {plan   => {count => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                ],
            },
        }
    });

    # Failing subtest
    $a->audit_event({
        facet_data => {
            assert => {pass => 0, details => 'beta'},
            parent => {
                hid      => 2,
                children => [
                    do { my $id = gen_uuid(); {assert => {pass => 0}, harness => {event_id => $id}, about => {uuid => $id}} },
                    do { my $id = gen_uuid(); {plan   => {count => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                ],
            },
        }
    });

    is($a->passing_subtests, ['alpha'], 'passing subtest tracked');
    is($a->failing_subtests, ['beta'],  'failing subtest tracked');
};

subtest 'nested subtest names do not leak into the top-level auditor lists' => sub {
    my $a = mk();
    $a->audit_event({facet_data => {plan => {count => 1}}});

    # Top-level subtest 'outer' whose children include another subtest 'inner'.
    # Only 'outer' should show up in the top auditor's passing_subtests.
    $a->audit_event({
        facet_data => {
            assert => {pass => 1, details => 'outer'},
            parent => {
                hid      => 1,
                children => [
                    do {
                        my $id = gen_uuid();
                        {
                            assert  => {pass => 1, details => 'inner'},
                            harness => {event_id => $id},
                            about   => {uuid     => $id},
                            parent  => {
                                hid      => 2,
                                children => [
                                    do { my $x = gen_uuid(); {assert => {pass => 1}, harness => {event_id => $x}, about => {uuid => $x}} },
                                    do { my $x = gen_uuid(); {plan   => {count => 1}, harness => {event_id => $x}, about => {uuid => $x}} },
                                ],
                            },
                        }
                    },
                    do { my $id = gen_uuid(); {plan => {count => 1}, harness => {event_id => $id}, about => {uuid => $id}} },
                ],
            },
        }
    });

    is($a->passing_subtests, ['outer'], 'only the top-level subtest name is kept');
    is($a->failing_subtests, [],        'no failing subtests recorded');
};

subtest 'event_id mismatch across facets is rejected' => sub {
    my $a  = mk();
    my $id = gen_uuid();
    my $ok = eval {
        $a->audit_event({
            event_id   => $id,
            facet_data => {
                harness => {event_id => $id},
                about   => {uuid     => gen_uuid()},
            },
        });
        1;
    };
    my $err = $@;
    ok(!$ok, 'croaks on mismatch');
    like($err, qr/event_id mismatch/, 'error mentions mismatch');
};

done_testing;
