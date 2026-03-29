use Test2::V0;

# Server controller tests require Plack, Text::Xslate, DBIx::Class etc.
# Skip gracefully if these heavy deps aren't installed.
my $can_load = eval {
    require App::Yath::Server::Controller::Upload;
    require App::Yath::Server::Response;
    1;
};
skip_all "Server dependencies not available: $@" unless $can_load;

my $CLASS = 'App::Yath::Server::Controller::Upload';

use File::Temp qw/tempfile/;

subtest 'process_form rejects oversized files with 413' => sub {
    # Create a temp file of known size (1024 bytes)
    my ($fh, $tmpfile) = tempfile(SUFFIX => '.jsonl.bz2', UNLINK => 1);
    print $fh 'x' x 1024;
    close $fh;

    my $upload = mock {} => (
        add => [
            filename => sub { 'test.jsonl.bz2' },
            tempname => sub { $tmpfile },
        ],
    );

    my $req = mock {} => (
        add => [
            method     => sub { 'POST' },
            parameters => sub { {action => 'upload log'} },
            uploads    => sub { {log_file => $upload} },
            user       => sub { mock {} => (add => [user_id => sub { 1 }]) },
        ],
    );

    # Schema mock returns a max of 512 bytes (smaller than our 1024-byte file)
    my $schema = mock {} => (
        add => [
            config => sub {
                my ($self, $setting) = @_;
                return 512 if $setting eq 'max_upload_size';
                return 0;
            },
        ],
    );

    my $schema_config = mock {} => (
        add => [
            schema => sub { $schema },
        ],
    );

    my $controller = $CLASS->new(
        request       => $req,
        schema_config => $schema_config,
        single_user   => 0,
        single_run    => 0,
    );

    my $res = App::Yath::Server::Response->new(200);

    my $err = dies { $controller->process_form($res) };
    ok($err, 'process_form dies on oversized file');
    isa_ok($err, ['App::Yath::Server::Response'], 'error is a Response object');
    is($err->status, 413, 'HTTP status is 413 Payload Too Large');
};

subtest 'process_form accepts files within size limit' => sub {
    # Create a small temp file (100 bytes, well under default 500MB)
    my ($fh, $tmpfile) = tempfile(SUFFIX => '.jsonl.bz2', UNLINK => 1);
    print $fh 'x' x 100;
    close $fh;

    my $upload = mock {} => (
        add => [
            filename => sub { 'test.jsonl.bz2' },
            tempname => sub { $tmpfile },
        ],
    );

    my $req = mock {} => (
        add => [
            method     => sub { 'POST' },
            parameters => sub { {action => 'upload log', project => 'test-proj', mode => 'qvfd'} },
            uploads    => sub { {log_file => $upload} },
            user       => sub { mock {} => (add => [user_id => sub { 1 }]) },
        ],
    );

    my $project = mock {} => (
        add => [project_id => sub { 1 }],
    );

    my $resultset_project = mock {} => (
        add => [find_or_create => sub { $project }],
    );

    my $schema = mock {} => (
        add => [
            config    => sub { 0 },  # No custom max → uses default 500MB
            resultset => sub { $resultset_project },
        ],
    );

    my $schema_config = mock {} => (
        add => [schema => sub { $schema }],
    );

    my $controller = $CLASS->new(
        request       => $req,
        schema_config => $schema_config,
        single_user   => 0,
        single_run    => 0,
    );

    my $res = App::Yath::Server::Response->new(200);

    # File passes size check. Will fail later at JSON decode — that's expected.
    # The key assertion: it does NOT die with a 413.
    my $err = dies { $controller->process_form($res) };
    if ($err && ref($err) && $err->can('status')) {
        isnt($err->status, 413, 'no 413 error — file passed size check');
    }
    else {
        pass('no 413 error — file passed size check (returned or died with non-HTTP error)');
    }
};

done_testing;
