use Test2::V0 -target => 'App::Yath::Renderer::Default::Composer';

# --- Construction ---

ok(my $c = $CLASS->new(), "can construct");
ref_ok($c, 'HASH', "instance is a hashref");

# --- Interface ---

can_ok($CLASS, qw/
    new
    render_one_line
    render_verbose
    render_super_verbose
    render_brief
    render_assert
    render_plan
    render_info
    render_errors
/);

# --- render_one_line: passing assert ---

{
    my $f = { assert => { pass => 1, details => 'test description' } };
    my $out = $c->render_one_line($f);
    ref_ok($out, 'ARRAY', "render_one_line returns arrayref for assert");
    is($out->[1], 'PASS', "tag is PASS for a passing assert");
}

# --- render_one_line: failing assert ---

{
    my $f = { assert => { pass => 0, details => 'oops' } };
    my $out = $c->render_one_line($f);
    ref_ok($out, 'ARRAY', "render_one_line returns arrayref for failing assert");
    is($out->[1], 'FAIL', "tag is FAIL for a failing assert");
}

# --- render_one_line: plan ---

{
    my $f = { plan => { count => 3 } };
    my $out = $c->render_one_line($f);
    ref_ok($out, 'ARRAY', "render_one_line returns arrayref for plan");
}

# --- render_one_line: empty facet_data returns undef ---

{
    my $out = $c->render_one_line({});
    ok(!defined($out), "render_one_line returns undef for empty facet data");
}

# --- render_verbose: returns arrayref of lines ---

{
    my $f = { plan => { count => 5 } };
    my $out = $c->render_verbose($f);
    ref_ok($out, 'ARRAY', "render_verbose returns arrayref");
    ok(scalar(@$out) > 0, "render_verbose returns at least one line for plan");
}

# --- render_verbose: passing assert ---

{
    my $f = { assert => { pass => 1, details => 'ok' } };
    my $out = $c->render_verbose($f);
    ref_ok($out, 'ARRAY', "render_verbose returns arrayref for passing assert");
    ok(scalar(@$out) > 0, "render_verbose returns lines for assert");
}

# --- render_verbose: failing assert includes debug output ---

{
    my $f = {
        assert => { pass => 0, details => 'nope' },
        errors => [{ tag => 'ERROR', details => 'something went wrong', fail => 1 }],
    };
    my $out = $c->render_verbose($f);
    ref_ok($out, 'ARRAY', "render_verbose returns arrayref for failing assert");
    ok(scalar(@$out) > 0, "render_verbose returns lines for failing assert");
}

# --- render_super_verbose: wraps render_verbose ---

{
    my $f = { assert => { pass => 1, details => 'test' } };
    my $out = $c->render_super_verbose($f);
    ref_ok($out, 'ARRAY', "render_super_verbose returns arrayref");
}

done_testing;
