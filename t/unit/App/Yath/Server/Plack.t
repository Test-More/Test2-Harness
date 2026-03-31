use Test2::V0;

BEGIN {
    my $ok = eval { require App::Yath::Server::Plack; 1 };
    skip_all "Server dependencies not installed" unless $ok;
}

use Test2::Harness::Util::JSON qw/decode_json/;
use App::Yath::Server::Plack;

subtest '_health_check returns 200 when DB ping succeeds' => sub {
    my $mock_dbh = mock {} => (
        add => [ping => sub { 1 }],
    );
    my $mock_storage = mock {} => (
        add => [dbh => sub { $mock_dbh }],
    );
    my $mock_schema = mock {} => (
        add => [
            storage => sub { $mock_storage },
            config  => sub { 0 },
        ],
    );
    my $mock_config = mock {} => (
        add => [schema => sub { $mock_schema }],
    );

    my $plack = App::Yath::Server::Plack->new(schema_config => $mock_config);

    my $env = {
        PATH_INFO      => '/health',
        REQUEST_METHOD => 'GET',
    };
    my $result = $plack->handle_request($env);

    is($result->[0], 200, 'status is 200');

    my $body = join('', @{$result->[2]});
    my $data = decode_json($body);
    is($data, {ok => 1}, 'body contains ok => 1');
};

subtest '_health_check returns 503 when DB ping fails' => sub {
    my $mock_dbh = mock {} => (
        add => [ping => sub { 0 }],
    );
    my $mock_storage = mock {} => (
        add => [dbh => sub { $mock_dbh }],
    );
    my $mock_schema = mock {} => (
        add => [
            storage => sub { $mock_storage },
            config  => sub { 0 },
        ],
    );
    my $mock_config = mock {} => (
        add => [schema => sub { $mock_schema }],
    );

    my $plack = App::Yath::Server::Plack->new(schema_config => $mock_config);

    my $env = {
        PATH_INFO      => '/health',
        REQUEST_METHOD => 'GET',
    };
    my $result = $plack->handle_request($env);

    is($result->[0], 503, 'status is 503');

    my $body = join('', @{$result->[2]});
    my $data = decode_json($body);
    is($data->{ok}, 0, 'ok is 0');
    like($data->{error}, qr/ping/, 'error mentions ping');
};

subtest '_health_check returns 503 when DB connection throws' => sub {
    my $mock_storage = mock {} => (
        add => [dbh => sub { die "Connection refused\n" }],
    );
    my $mock_schema = mock {} => (
        add => [
            storage => sub { $mock_storage },
            config  => sub { 0 },
        ],
    );
    my $mock_config = mock {} => (
        add => [schema => sub { $mock_schema }],
    );

    my $plack = App::Yath::Server::Plack->new(schema_config => $mock_config);

    my $env = {
        PATH_INFO      => '/health',
        REQUEST_METHOD => 'GET',
    };
    my $result = $plack->handle_request($env);

    is($result->[0], 503, 'status is 503');

    my $body = join('', @{$result->[2]});
    my $data = decode_json($body);
    is($data->{ok}, 0, 'ok is 0');
    like($data->{error}, qr/Connection refused/, 'error captures exception message');
};

subtest '/health only responds to GET' => sub {
    my $health_called = 0;
    my $mock_dbh = mock {} => (
        add => [ping => sub { $health_called++; 1 }],
    );
    my $mock_storage = mock {} => (
        add => [dbh => sub { $mock_dbh }],
    );
    my $mock_schema = mock {} => (
        add => [
            storage => sub { $mock_storage },
            config  => sub { 0 },
        ],
    );
    my $mock_config = mock {} => (
        add => [schema => sub { $mock_schema }],
    );

    my $plack = App::Yath::Server::Plack->new(schema_config => $mock_config);

    # GET /health should trigger the health check
    my $get_result = $plack->handle_request({
        PATH_INFO      => '/health',
        REQUEST_METHOD => 'GET',
    });
    is($get_result->[0], 200, 'GET /health returns 200');
    is($health_called, 1, 'health check was invoked for GET');

    # POST /health should NOT trigger the health check — it falls through
    $health_called = 0;
    my $post_result = eval { $plack->handle_request({
        PATH_INFO      => '/health',
        REQUEST_METHOD => 'POST',
    }) };
    is($health_called, 0, 'health check was NOT invoked for POST');
};

done_testing;
