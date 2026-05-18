use Test2::V0;
use App::Yath2::Formatter::Txt;

my $f = App::Yath2::Formatter::Txt->new;

# produces_artifact is now 1 — facet coverage is complete.
is($f->produces_artifact, 1, 'produces_artifact is 1 after full facet coverage');
isa_ok($f, ['App::Yath2::Formatter']);

# ---------------------------------------------------------------------------
# assert — pass
# ---------------------------------------------------------------------------
subtest 'assert pass' => sub {
    my $item = {facet_data => {assert => {pass => 1, details => 'basic test'}}};
    my $out  = $f->convert_item($item);
    like($out, qr/PASS: basic test/, 'renders PASS tag and name');
    unlike($out, qr/DEBUG:/, 'no debug line on pass');
};

# ---------------------------------------------------------------------------
# assert — fail (includes DEBUG from trace)
# ---------------------------------------------------------------------------
subtest 'assert fail with trace' => sub {
    my $item = {
        facet_data => {
            assert => {pass  => 0, details => 'broken test'},
            trace  => {frame => ['pkg', 'foo.t', 42]},
        }
    };
    my $out = $f->convert_item($item);
    like($out, qr/FAIL: broken test/,     'renders FAIL tag and name');
    like($out, qr/DEBUG: foo\.t line 42/, 'renders trace location');
};

# ---------------------------------------------------------------------------
# assert — fail, no_debug suppresses DEBUG line
# ---------------------------------------------------------------------------
subtest 'assert fail no_debug' => sub {
    my $item = {facet_data => {assert => {pass => 0, details => 'silent', no_debug => 1}}};
    my $out  = $f->convert_item($item);
    like($out, qr/FAIL: silent/, 'renders FAIL');
    unlike($out, qr/DEBUG:/, 'no DEBUG when no_debug set');
};

# ---------------------------------------------------------------------------
# assert — fail, trace details string
# ---------------------------------------------------------------------------
subtest 'assert fail with trace details string' => sub {
    my $item = {
        facet_data => {
            assert => {pass    => 0, details => 'bad'},
            trace  => {details => 'main.t line 7'},
        }
    };
    my $out = $f->convert_item($item);
    like($out, qr/DEBUG: main\.t line 7/, 'renders trace details string');
};

# ---------------------------------------------------------------------------
# assert — fail, no trace at all
# ---------------------------------------------------------------------------
subtest 'assert fail no trace' => sub {
    my $item = {facet_data => {assert => {pass => 0, details => 'untraceable'}}};
    my $out  = $f->convert_item($item);
    like($out, qr/DEBUG: \[No trace info available\]/, 'fallback debug message');
};

# ---------------------------------------------------------------------------
# amnesty — TODO (! PASS ! tag, amnesty reason appended)
# ---------------------------------------------------------------------------
subtest 'assert with amnesty (TODO)' => sub {
    my $item = {
        facet_data => {
            assert  => {pass => 0, details => 'todo test'},
            amnesty => [{tag => 'TODO', details => 'not yet'}],
        }
    };
    my $out = $f->convert_item($item);
    like($out, qr/! PASS !: todo test/, 'amnesty changes tag to ! PASS !');
    like($out, qr/TODO: not yet/,       'amnesty reason line emitted');
    unlike($out, qr/DEBUG:/, 'no DEBUG when amnesty present');
};

# ---------------------------------------------------------------------------
# amnesty — deduplication
# ---------------------------------------------------------------------------
subtest 'amnesty deduplication' => sub {
    my $item = {
        facet_data => {
            assert  => {pass => 1, details => 'dup'},
            amnesty => [
                {tag => 'TODO', details => 'same'},
                {tag => 'TODO', details => 'same'},
            ],
        }
    };
    my $out     = $f->convert_item($item);
    my @matches = ($out =~ /TODO: same/g);
    is(scalar @matches, 1, 'duplicate amnesty entries are deduplicated');
};

# ---------------------------------------------------------------------------
# info — basic note/diag
# ---------------------------------------------------------------------------
subtest 'info basic' => sub {
    my $item = {facet_data => {info => [{tag => 'note', details => 'banner'}]}};
    like($f->convert_item($item), qr/note: banner/, 'renders info tag and details');
};

# ---------------------------------------------------------------------------
# info — multi-line
# ---------------------------------------------------------------------------
subtest 'info multi-line' => sub {
    my $item = {
        facet_data => {
            info => [
                {tag => 'note', details => 'line1'},
                {tag => 'diag', details => 'line2'},
            ]
        }
    };
    my $out = $f->convert_item($item);
    like($out, qr/note: line1/, 'first info line');
    like($out, qr/diag: line2/, 'second info line');
};

# ---------------------------------------------------------------------------
# errors
# ---------------------------------------------------------------------------
subtest 'errors — non-fatal' => sub {
    my $item = {facet_data => {errors => [{details => 'something went wrong'}]}};
    my $out  = $f->convert_item($item);
    like($out, qr/ERROR: something went wrong/, 'default ERROR tag');
};

subtest 'errors — fatal' => sub {
    my $item = {facet_data => {errors => [{details => 'boom', fail => 1}]}};
    my $out  = $f->convert_item($item);
    like($out, qr/FATAL: boom/, 'fail => 1 produces FATAL tag');
};

subtest 'errors — explicit tag' => sub {
    my $item = {facet_data => {errors => [{details => 'oops', tag => 'TIMEOUT'}]}};
    my $out  = $f->convert_item($item);
    like($out, qr/TIMEOUT: oops/, 'explicit tag on error entry');
};

# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------
subtest 'plan — count' => sub {
    my $item = {facet_data => {plan => {count => 12}}};
    like($f->convert_item($item), qr/PLAN: Expected assertions: 12/, 'plan count line');
};

subtest 'plan — skip all with reason' => sub {
    my $item = {facet_data => {plan => {skip => 1, details => 'no DB'}}};
    like($f->convert_item($item), qr/SKIP ALL: no DB/, 'skip-all with reason');
};

subtest 'plan — skip all no reason' => sub {
    my $item = {facet_data => {plan => {skip => 1}}};
    like($f->convert_item($item), qr/SKIP ALL: No reason given/, 'skip-all fallback reason');
};

subtest 'plan — no plan' => sub {
    my $item = {facet_data => {plan => {none => 1, details => 'stream'}}};
    like($f->convert_item($item), qr/NO PLAN:/, 'no-plan line');
};

# ---------------------------------------------------------------------------
# control
# ---------------------------------------------------------------------------
subtest 'control — halt' => sub {
    my $item = {facet_data => {control => {halt => 1, details => 'bail out reason'}}};
    my $out  = $f->convert_item($item);
    like($out, qr/HALT: bail out reason/, 'halt renders with details');
};

subtest 'control — halt with no details' => sub {
    my $item = {facet_data => {control => {halt => 1}}};
    my $out  = $f->convert_item($item);
    like($out, qr/HALT:/, 'halt renders even without details');
};

# ---------------------------------------------------------------------------
# about — fallback
# ---------------------------------------------------------------------------
subtest 'about — shown when nothing else matches' => sub {
    my $item = {facet_data => {about => {details => 'some event type'}}};
    my $out  = $f->convert_item($item);
    like($out, qr/ABOUT: some event type/, 'about rendered as fallback');
};

subtest 'about — suppressed when other facets produced output' => sub {
    my $item = {
        facet_data => {
            assert => {pass    => 1, details => 'wins'},
            about  => {details => 'should not appear'},
        }
    };
    my $out = $f->convert_item($item);
    unlike($out, qr/ABOUT:/, 'about suppressed when assert present');
};

subtest 'about — no_display flag' => sub {
    my $item = {facet_data => {about => {details => 'hidden', no_display => 1}}};
    is($f->convert_item($item), '', 'no_display about produces empty string');
};

subtest 'about — uses short package name' => sub {
    my $item = {facet_data => {about => {details => 'pkg event', package => 'Test2::Event::Ok'}}};
    my $out  = $f->convert_item($item);
    like($out, qr/Ok: pkg event/, 'about uses short package name as tag');
};

# ---------------------------------------------------------------------------
# harness_job lifecycle markers
# ---------------------------------------------------------------------------
subtest 'harness_job_launch' => sub {
    my $item = {facet_data => {harness_job_launch => {stamp => '1234567890'}}};
    like($f->convert_item($item), qr/HARNESS: Job Launched at 1234567890/, 'launch stamp');
};

subtest 'harness_job_start' => sub {
    my $item = {facet_data => {harness_job_start => {details => 'started foo.t'}}};
    like($f->convert_item($item), qr/HARNESS: started foo\.t/, 'start details');
};

subtest 'harness_job_exit' => sub {
    my $item = {facet_data => {harness_job_exit => {details => 'exit 0'}}};
    like($f->convert_item($item), qr/HARNESS: exit 0/, 'exit details');
};

subtest 'harness_job_end' => sub {
    my $item = {facet_data => {harness_job_end => {stamp => '9876543210'}}};
    like($f->convert_item($item), qr/HARNESS: Job completed at 9876543210/, 'end stamp');
};

# ---------------------------------------------------------------------------
# parent — subtest recursion + indentation
# ---------------------------------------------------------------------------
subtest 'parent — recursive children indented' => sub {
    my $child1 = {
        facet_data => {assert => {pass => 1, details => 'child pass'}},
    };
    my $child2 = {
        facet_data => {assert => {pass => 0, details => 'child fail', no_debug => 1}},
    };
    my $item = {
        facet_data => {
            assert => {pass     => 0, details => 'subtest name', no_debug => 1},
            parent => {children => [$child1, $child2]},
        }
    };
    my $out = $f->convert_item($item);

    like($out, qr/FAIL: subtest name/, 'parent assert line rendered');
    like($out, qr/  PASS: child pass/, 'child 1 indented by 2 spaces');
    like($out, qr/  FAIL: child fail/, 'child 2 indented by 2 spaces');
};

subtest 'parent — nested subtests indent accumulates' => sub {
    my $grandchild = {
        facet_data => {assert => {pass => 1, details => 'deep'}},
    };
    my $child = {
        facet_data => {
            assert => {pass     => 1, details => 'mid', no_debug => 1},
            parent => {children => [$grandchild]},
        }
    };
    my $item = {
        facet_data => {
            assert => {pass     => 1, details => 'outer'},
            parent => {children => [$child]},
        }
    };
    my $out = $f->convert_item($item);
    like($out, qr/PASS: outer/,    'outer assertion present');
    like($out, qr/  PASS: mid/,    'child indented 2 spaces');
    like($out, qr/    PASS: deep/, 'grandchild indented 4 spaces');
};

# ---------------------------------------------------------------------------
# no facets → empty string
# ---------------------------------------------------------------------------
subtest 'no facets' => sub {
    is($f->convert_item({facet_data => {}}), '', 'no facets => empty string');
    is($f->convert_item({}),                 '', 'no facet_data => empty string');
};

done_testing;
