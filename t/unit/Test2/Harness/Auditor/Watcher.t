use Test2::V0 -target => 'Test2::Harness::Auditor::Watcher';

use Test2::Harness::Collector::TapParser qw/parse_stdout_tap/;
use Test2::Harness::Event;

my $EVENT_ID = 1;

sub harness_event {
    my ($facet_data) = @_;

    return Test2::Harness::Event->new(
        run_id     => 'run',
        job_id     => 'job',
        job_try    => 0,
        event_id   => 'event-' . $EVENT_ID++,
        facet_data => $facet_data,
    );
}

sub harness_output_event {
    my ($line, $tag) = @_;

    return harness_event({info => [{details => $line, tag => $tag, debug => $tag eq 'STDERR' ? 1 : 0}]});
}

# A pair of nested streamed subtests, as a test that does not use the event
# stream writes them.
my @TAP = (
    '# Subtest: foo',
    '    # Subtest: bar',
    '        ok 1 - baz',
    '        1..1',
    '    ok 1 - bar',
    '    1..1',
    'ok 1 - foo',
    '1..1',
);

sub watch {
    my (%params) = @_;

    my $watcher = $CLASS->new(job => {job_id => 'job'}, try => 0);

    for my $idx (0 .. $#TAP) {
        $watcher->process(harness_output_event($params{noise}, $params{tag} || 'STDERR'))
            if defined($params{noise_at}) && $params{noise_at} == $idx;

        $watcher->process(harness_event(parse_stdout_tap($TAP[$idx])));
    }

    return $watcher;
}

subtest clean_run => sub {
    my $watcher = watch();

    ok($watcher->pass, "Nested subtests passed");
    is($watcher->assertion_count, 1, "Counted the top level assertion");
};

subtest output_does_not_close_subtests => sub {
    # A module warning (Test2::Util::UUID does this when it falls back to
    # UUID::Tiny) lands in the middle of the subtest TAP. It is not indented,
    # but it is not TAP either, so it must not end the subtest.
    for my $idx (0 .. $#TAP) {
        for my $tag (qw/STDERR STDOUT/) {
            my $watcher = watch(noise_at => $idx, noise => 'noise from a module', tag => $tag);

            ok($watcher->pass, "$tag before TAP line $idx did not fail the job")
                or diag(join "\n" => map { $_->{details} } $watcher->fail_error_facet_list);

            is($watcher->assertion_count, 1, "$tag before TAP line $idx left the assertion count alone");
        }
    }
};

subtest tap_still_closes_subtests => sub {
    my $watcher = $CLASS->new(job => {job_id => 'job'}, try => 0);

    # The inner subtest never gets its plan or its result line, the outer one
    # closes it.
    $watcher->process(harness_event(parse_stdout_tap($_))) for (
        '# Subtest: foo',
        '    # Subtest: bar',
        '        ok 1 - baz',
        '        1..2',
        'ok 1 - foo',
        '1..1',
    );

    ok($watcher->fail, "Incomplete subtest was caught");
};

done_testing;
