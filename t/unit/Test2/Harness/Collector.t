use Test2::V0 -target => 'Test2::Harness::Collector';

my $CLASS = CLASS();

subtest 'can be loaded' => sub {
    ok($CLASS, "CLASS() returns the package name");
    ok($CLASS->isa('Test2::Harness::Collector'), "is correct class");
};

subtest 'has expected accessor methods' => sub {
    for my $method (qw/
        run_id job_id job_try
        parser output
        workdir tempdir
        run job
        interactive always_flush
        merge_outputs encoding
    /) {
        ok($CLASS->can($method), "has '$method' accessor/method");
    }
};

subtest 'constructor requires parser' => sub {
    like(
        dies { $CLASS->new(output => sub {}) },
        qr/parser.*required/i,
        "missing parser dies"
    );
};

subtest 'constructor requires output' => sub {
    my $dummy_parser = bless {}, 'Test2::Harness::Collector::IOParser';
    like(
        dies { $CLASS->new(parser => $dummy_parser) },
        qr/output.*required/i,
        "missing output dies"
    );
};

subtest 'constructor with coderef output' => sub {
    my $dummy_parser = bless {}, 'Test2::Harness::Collector::IOParser';
    my @received;
    my $obj = $CLASS->new(
        parser => $dummy_parser,
        output => sub { push @received, @_ },
    );
    ok($obj, "object created with coderef output");
    ok($obj->can('output_cb') ? $obj->output_cb : $obj->can('_output_cb'), "output_cb is set");
};

subtest 'constructor with GLOB output' => sub {
    my $dummy_parser = bless {}, 'Test2::Harness::Collector::IOParser';
    open(my $fh, '>', \my $buf) or die "Cannot open string ref: $!";
    my $obj = $CLASS->new(
        parser => $dummy_parser,
        output => $fh,
    );
    ok($obj, "object created with GLOB output");
};

subtest 'constructor with unknown output type dies' => sub {
    my $dummy_parser = bless {}, 'Test2::Harness::Collector::IOParser';
    like(
        dies { $CLASS->new(parser => $dummy_parser, output => "not a valid type") },
        qr/Unknown output type/i,
        "unknown output type dies"
    );
};

subtest 'default field values after construction' => sub {
    my $dummy_parser = bless {}, 'Test2::Harness::Collector::IOParser';
    my $obj = $CLASS->new(
        parser => $dummy_parser,
        output => sub {},
    );
    is($obj->run_id,  0, "run_id defaults to 0");
    is($obj->job_id,  0, "job_id defaults to 0");
    is($obj->job_try, 0, "job_try defaults to 0");
    ok(!$obj->merge_outputs, "merge_outputs defaults to false");
};

subtest 'handles set up during construction' => sub {
    my $dummy_parser = bless {}, 'Test2::Harness::Collector::IOParser';
    my $obj = $CLASS->new(
        parser => $dummy_parser,
        output => sub {},
    );
    my $handles = $obj->handles;
    ok(ref($handles) eq 'HASH', "handles is a hash ref");
    ok($handles->{out_r}, "out_r handle set");
    ok($handles->{out_w}, "out_w handle set");
    ok($handles->{err_r}, "err_r handle set");
    ok($handles->{err_w}, "err_w handle set");
};

subtest 'merge_outputs shares out/err handles' => sub {
    my $dummy_parser = bless {}, 'Test2::Harness::Collector::IOParser';
    my $obj = $CLASS->new(
        parser        => $dummy_parser,
        output        => sub {},
        merge_outputs => 1,
    );
    my $handles = $obj->handles;
    is($handles->{out_r}, $handles->{err_r}, "out_r and err_r are same when merging");
    is($handles->{out_w}, $handles->{err_w}, "out_w and err_w are same when merging");
};

done_testing;
