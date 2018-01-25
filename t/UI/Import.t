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
    is($res, {errors => ['error processing event number 0: Duplicate event']}, "Noticed duplicate");

    my $control = mock $CLASS => (
        'override' => [ import_facet => sub { die "fake error" } ],
    );

    my $warnings = warnings { ok(lives { $res = $one->import_events($json) }, "Did not die") };
    is($res, {errors => [ "Internal Error" ], internal_error => 1}, "Exception causes internal error");
    like($warnings, [qr/^fake error/], "Got exception as warning");
};

tests format_stamp => sub {
    my $fmt = $CLASS->can('format_stamp');

    my $base_stamp = 1516906552;
    my $base_fmted = '2018-01-25T18:55:52';

    is($fmt->($base_stamp), $base_fmted, "Formatted base stamp");
    is($fmt->($base_stamp . ".5"), "$base_fmted.5", "Kept decimals");

    my $exp_stamp = sprintf("%.10e", "$base_stamp.5");
    is($fmt->($exp_stamp), "$base_fmted.5", "From exponent form");
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

done_testing;

__END__

sub process_params {
    my $self = shift;
    my ($params) = @_;

    $params = decode_json($params) unless ref $params;

    # Verify credentials
    my $key = $self->verify_credentials($params->{api_key})
        or return {errors => ["Incorrect credentials"]};

    # Verify or create feed
    my ($feed, $error) = $self->find_feed($key, $params);
    return $error if $error;

    my $cnt = 0;
    for my $event (@{$params->{events}}) {
        my $error = $self->import_event($feed, $event);
        return {errors => ["error processing event number $cnt: $error"]} if $error;
        $cnt++;
    }

    return {success => 1, events_added => $cnt, feed => $feed->feed_ui_id};
}

sub import_event {
    my $self = shift;
    my ($feed, $event_data) = @_;

    my $schema = $self->{+SCHEMA};

    my $run_id = $event_data->{run_id};
    return "no run_id provided" unless defined $run_id;
    my $run = $schema->resultset('Run')->find_or_create({feed_ui_id => $feed->feed_ui_id, run_id => $run_id, permissions => $feed->permissions})
        or die "Unable to find/add run: $run_id";

    my $job_id = $event_data->{job_id};
    return "no job_id provided" unless defined $job_id;
    my $job = $schema->resultset('Job')->find_or_create({job_id => $job_id, run_ui_id => $run->run_ui_id, permissions => $feed->permissions})
        or die "Unable to find/add job: $job_id";

    my $new_data = {
        job_ui_id => $job->job_ui_id,
        event_id  => $event_data->{event_id},
    };

    return "Duplicate event" if $schema->resultset('Event')->find($new_data);

    $new_data->{stamp}     = format_stamp($event_data->{stamp});
    $new_data->{stream_id} = $event_data->{stream_id};

    my $event = $schema->resultset('Event')->create($new_data)
        or die "Could not create event";

    my $facets = $event_data->{facet_data} || {};
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
