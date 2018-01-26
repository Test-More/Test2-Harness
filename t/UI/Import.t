use Test2::V0 -target => 'Test2::Harness::UI::Import';
use Test2::Tools::Spec;
use Test2::Harness::Util::JSON qw/decode_json/;

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();
my $schema = $db->connect;

tests init => sub {
    like(dies { $CLASS->new }, qr/'schema' is a required attribute/, "Need schema");

    ok(my $one = $CLASS->new(schema => $schema), "Construction");

    isa_ok($one, $CLASS);
};

tests integration => sub {
    my $one = $CLASS->new(schema => $schema);
    my $user = $schema->resultset('User')->create({username => 'foo', password => 'foo'});

    open(my $fh, '<', 't/simple.json') or die "Could not open simple.json: $!";
    my $json = join '' => <$fh>;
    close($fh);
    my $res;
    ok(lives { $res = $one->import_events($json) }, "Did not die");
    is($res, {success => 1, events_added => 8, feed => T()}, "Got the expected result");

    ok(lives { $res = $one->import_events($json) }, "Did not die");
    is($res, {success => 1, events_added => 8, feed => T()}, "Got the expected result a second time");

    # Duplicate data
    my $data = decode_json($json);
    $data->{feed} = $res->{feed};
    ok(lives { $res = $one->import_events($data) }, "Did not die");
    is($res, {errors => ['error processing event number 0: Duplicate Event']}, "Noticed duplicate");

    my $control = mock $CLASS => (
        'override' => [ import_facet => sub { die "fake error" } ],
    );

    my $warnings = warnings { ok(lives { $res = $one->import_events($json) }, "Did not die") };
    is($res, {errors => [ "Internal Error" ], internal_error => 1}, "Exception causes internal error");
    like($warnings, [qr/^fake error/], "Got exception as warning");
};

tests format_stamp => sub {
    my $fmt = $CLASS->can('format_stamp');

    is($fmt->(), undef, "No stamp, no datetime");
    isa_ok($fmt->(1516906552.123), ['DateTime'], "Got a datetime object");
};

tests verify_credentials => sub {
    my $one = $CLASS->new(schema => $schema);

    ok(!$one->verify_credentials(), "No key");
    ok(!$one->verify_credentials('xxx'), "invalid key");

    my $key = $schema->resultset('User')->find({username => 'simple'})->gen_api_key('blah');
    ok($one->verify_credentials($key->value), "Good api key");
    $key->update({status => 'revoked'});
    ok(!$one->verify_credentials($key->value), "Revoked api key");
};

tests find_feed => sub {
    my $one = $CLASS->new(schema => $schema);
    my $user = $schema->resultset('User')->find({username => 'simple'});
    my $key = $user->api_keys->first;

    ok(my $new_feed = $one->find_feed($key, {}), "Generated a new feed");

    ok(my $found = $one->find_feed($user, {feed => $new_feed->feed_ui_id}), "Found existing feed");
    is($found->feed_ui_id, $new_feed->feed_ui_id, "Same id");

    my ($res, $err) = $one->find_feed($user, {feed => $new_feed->feed_ui_id, permissions => 'public'});
    is($err, {errors => ['permissions (public) do not match established permissions (private) for this feed (' . $new_feed->feed_ui_id. ')']}, "Permissions check");

    my $user2 = $schema->resultset('User')->create({
        username => 'bob',
        password => 'simple',
    });
    my $key2 = $user2->gen_api_key('another');

    ($res, $err) = $one->find_feed($key2, {feed => $new_feed->feed_ui_id, permissions => 'private'});
    is($err, {errors => ['Invalid feed']}, "Wrong user, invalid feed");

    ($res, $err) = $one->find_feed($key2, {feed => '999'});
    is($err, {errors => ['Invalid feed']}, "Invalid feed id");
};

describe import_events => sub {
    my $one = $CLASS->new(schema => $schema);

    my $cb;
    mock $CLASS => (override => [process_params => sub { goto &$cb }]);

    tests args => {flat => 1}, sub {
        my $args;
        $cb = sub { $args = [@_]; return {1 => 1}; };

        $one->import_events('foo');
        is($args, [exact_ref($one), 'foo'], "got args");
    };

    tests success => sub {
        my $user_id;
        $cb = sub {
            $user_id = $schema->resultset('User')->create({username => 'lars', password => 'lars'})->user_ui_id;
            return { success => 1 };
        };

        is(
            $one->import_events(),
            {success => 1},
            "Got response"
        );

        ok($schema->resultset('User')->find({username => 'lars'}), "user was added, transaction did not roll back");
    };

    tests errors => sub {
        my $user_id;
        $cb = sub {
            $user_id = $schema->resultset('User')->create({username => 'mars', password => 'mars'})->user_ui_id;
            return { errors => [1] };
        };

        is(
            $one->import_events(),
            {errors => [1]},
            "Got response"
        );

        ok(!$schema->resultset('User')->find({username => 'mars'}), "user was not added, transaction rolled back");
    };

    tests exception => sub {
        my $user_id;
        $cb = sub {
            $user_id = $schema->resultset('User')->create({username => 'bars', password => 'bars'})->user_ui_id;
            die "oops";
        };

        my $warnings = warnings {
            is(
                $one->import_events(),
                {errors => ["Internal Error"], internal_error => 1},
                "Got internal error"
            );
        };

        like($warnings, [qr/^oops/], "got warnings");

        ok(!$schema->resultset('User')->find({username => 'bars'}), "user was not added, transaction rolled back");
    };
};

tests process_params => sub {
    my $one = $CLASS->new(schema => $schema);

    my ($vc, @ff, $ie);
    my $control = mock $CLASS => (
        override => [
            verify_credentials => sub { return $vc },
            find_feed          => sub { return @ff },
            import_event       => sub { return $ie },
        ],
    );

    $vc = undef;
    is(
        $one->process_params({}),
        {errors => ["Incorrect credentials"]},
        "Credential failure"
    );

    $vc = 1;
    @ff = ({}, {errors => ["foo"]});
    is(
        $one->process_params({}),
        {errors => ["foo"]},
        "Find feed error"
    );

    @ff = mock {feed_ui_id => 43};
    $ie = "xxx xxx";
    is(
        $one->process_params({events => [{}]}),
        {errors => ["error processing event number 0: xxx xxx"]},
        "Event import error"
    );

    $ie = undef;
    is(
        $one->process_params({events => [{}, {}, {}]}),
        {success => 1, events_added => 3, feed => 43},
        "Success"
    );
};

tests vivify_row => sub {
    my $one = $CLASS->new(schema => $schema);

    my (undef, $error) = $one->vivify_row('Run', 'run_id', {}, {});
    is($error, "No run_id provided", "Must provide the key");

    ok(my $new = $one->vivify_row('Run', 'run_id', {feed_ui_id => 1, run_id => 'foo'}, {permissions => 'protected'}), "Created a new one");
    is($new->run_id, 'foo', "set the run_id");
    is($new->permissions, 'protected', "set the permissions");

    ok(my $found = $one->vivify_row('Run', 'run_id', {feed_ui_id => 1, run_id => 'foo'}, {permissions => 'public'}), "Found an existing one");
    is($new->run_id, 'foo', "got the run_id");
    is($new->permissions, 'protected', "did not change the permissions");
};

tests unique_row => sub {
    my $one = $CLASS->new(schema => $schema);

    my (undef, $oops) = $one->unique_row('Event', 'event_id', {job_ui_id => 1}, {stream_id => 'foo'});
    is($oops, "No event_id provided", "need event_id");

    my ($new, $error) = $one->unique_row('Event', 'event_id', {job_ui_id => 1, event_id => 'fake-event'}, {stream_id => 'foo'});
    ok(!$error, "No error");
    ok($new, "Make a new row");
    is($new->stream_id, 'foo', "set stream id");

    (my $f, $error) = $one->unique_row('Event', 'event_id', {job_ui_id => 1, event_id => 'fake-event'}, {stream_id => 'anything'});
    ok(!$f, "no object returned");
    is($error, "Duplicate Event", "Got error");
};

tests import_event => sub {
    my $one = $CLASS->new(schema => $schema);

    my $feed = $schema->resultset('Feed')->find({feed_ui_id => 1});

    is($one->import_event($feed, {}), "No run_id provided", "need run_id");
    is($one->import_event($feed, {run_id => "foo"}), "No job_id provided", "need job_id");
    is($one->import_event($feed, {run_id => "foo", job_id => "foo"}), "No event_id provided", "need event_id");
    is($one->import_event($feed, {run_id => "foo", job_id => "foo", event_id => 'foo'}), undef, "No error");
    is($one->import_event($feed, {run_id => "foo", job_id => "foo", event_id => 'foo'}), "Duplicate Event", "Duplicate");
};

tests import_facets => sub {
    my $one = $CLASS->new(schema => $schema);
    
};

done_testing;

__END__

sub import_facets {
    my $self = shift;
    my ($run, $job, $event, $facets) = @_;

    return unless $facets;

    my $cnt = 0;
    for my $facet_name (keys %$facets) {
        my $val = $facets->{$facet_name} or next;

        unless (ref($val) eq 'ARRAY') {
            $self->import_facet($run, $job, $event, $facet_name, $val, $cnt++);
            next;
        }

        $self->import_facet($run, $job, $event, $facet_name, $_, $cnt++) for @$val;
    }

    return;
}

sub import_facet {
    my $self = shift;
    my ($run, $job, $event, $facet_name, $val, $cnt) = @_;

    my $schema = $self->{+SCHEMA};

    my $facet = $schema->resultset('Facet')->create(
        {
            event_ui_id => $event->event_ui_id,
            facet_name  => $facet_name,
            facet_value => encode_json($val),
        }
    );
    die "Could not add facet '$facet_name' number $cnt" unless $facet;

    $run->update({facet_ui_id     => $facet->facet_ui_id}) if $facet_name eq 'harness_run' && !$run->facet_ui_id;
    $job->update({job_facet_ui_id => $facet->facet_ui_id}) if $facet_name eq 'harness_job' && !$job->job_facet_ui_id;
    $job->update({end_facet_ui_id => $facet->facet_ui_id, file => $val->{file}, fail => $val->{fail}}) if $facet_name eq 'harness_job_end' && !$job->end_facet_ui_id;
}

1;
