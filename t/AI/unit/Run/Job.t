use Test2::V0;
use v5.38;

use File::Spec ();

use Test2::Harness2::Run::Job;

# Run::Job is the final, static description of one test file. It carries all the
# scan-derived state but never builds or sniffs it.

my %REQ = (run_uuid => 'R', run_ord => 1, job_uuid => 'J', job_ord => 1);

subtest required_attrs => sub {
    like(dies { Test2::Harness2::Run::Job->new(%REQ, file => 'a.t', run_uuid => undef) }, qr/'run_uuid' is a required/, "run_uuid required");
    like(dies { Test2::Harness2::Run::Job->new(%REQ, file => 'a.t', run_ord  => undef) }, qr/'run_ord' is a required/,  "run_ord required");
    like(dies { Test2::Harness2::Run::Job->new(%REQ, file => 'a.t', job_uuid => undef) }, qr/'job_uuid' is a required/, "job_uuid required");
    like(dies { Test2::Harness2::Run::Job->new(%REQ, file => 'a.t', job_ord  => undef) }, qr/'job_ord' is a required/,  "job_ord required");
    like(dies { Test2::Harness2::Run::Job->new(%REQ) }, qr/'absolute' \(or 'file'\) is a required/, "needs a path");
};

subtest path_derivation => sub {
    my $job = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t');
    is($job->relative, 'a.t', "relative derived from file");
    is($job->absolute, File::Spec->rel2abs('a.t'), "absolute derived from file");
    ok(!exists $job->{file}, "the file convenience key is discarded");

    my $abs = Test2::Harness2::Run::Job->new(%REQ, absolute => '/x/y.t');
    is($abs->relative, File::Spec->abs2rel('/x/y.t'), "relative derived from absolute");
};

subtest runtime_state => sub {
    my $job = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t');
    is($job->try, 1, "try defaults to 1");
    is($job->state, 'pending', "state defaults to pending");

    $job->set_state('running');
    is($job->state, 'running', "state is mutable");
    $job->set_try(2);
    is($job->try, 2, "try is mutable");
};

subtest defaults => sub {
    my $job = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t');

    is($job->min_slots, 1, "min_slots default");
    is($job->max_slots, undef, "max_slots default");
    is($job->comment, '#', "comment default");
    is($job->conflicts, [], "conflicts default");
    is($job->switches, [], "switches default");
    is($job->features, {}, "features default");
    is($job->meta, {}, "meta default");
    is($job->preload_preferences, ['<default>'], "preload_preferences default");
    is($job->smoke, 0, "smoke default");
    is($job->isolation, 0, "isolation default");
    is($job->retry, 0, "retry default");
    is($job->retry_isolated, 0, "retry_isolated default");
    is($job->non_perl, 0, "non_perl default");
    is($job->is_binary, 0, "is_binary default");
    is($job->category, undef, "category default undef");
    is($job->duration, undef, "duration default undef");
    is($job->stage, undef, "stage default undef");
};

subtest containers_are_fresh => sub {
    my $job = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t');
    push @{$job->conflicts}, 'leak';
    is($job->conflicts, [], "a mutated default arrayref does not persist");
};

subtest helpers => sub {
    my $job = Test2::Harness2::Run::Job->new(
        %REQ,
        file      => 'a.t',
        category  => undef,
        duration  => undef,
        conflicts => ['db', 'net'],
        features  => {fork => 0},
        meta      => {tags => ['x', 'y']},
    );

    is($job->check_category, 'general', "check_category fallback");
    is($job->check_duration, 'medium', "check_duration fallback");
    is($job->feature('fork'), 0, "feature reads raw value");
    is($job->check_feature('fork'), 0, "check_feature 0/1 of explicit value");
    is($job->check_feature('stream'), 1, "check_feature internal default");
    is($job->check_feature('nope', 7), 7, "check_feature honors passed default");
    is([sort $job->conflicts_list], ['db', 'net'], "conflicts_list");
    ok($job->has_conflicts, "has_conflicts true");
    is([$job->meta_get('tags')], ['x', 'y'], "meta_get returns list");
    is([$job->meta_get('missing')], [], "meta_get empty for missing key");
};

subtest rank => sub {
    my $smoke = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t', features => {smoke => 1});
    is($smoke->rank, 1, "smoke ranks first");

    my $short = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t', duration => 'short');
    is($short->rank, 80, "duration drives rank when no category");

    my $plain = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t');
    is($plain->rank, 50, "falls back to medium duration rank");
};

subtest to_json => sub {
    my $job = Test2::Harness2::Run::Job->new(%REQ, file => 'a.t', category => 'general');
    my $data = $job->TO_JSON;
    is($data->{job_uuid}, 'J', "carries job_uuid");
    is($data->{relative}, 'a.t', "carries relative");
    is($data->{category}, 'general', "carries category");
    is($data->{min_slots}, 1, "emits default-aware values");
    ok(!exists $data->{file}, "no stray file key");
};

done_testing;
