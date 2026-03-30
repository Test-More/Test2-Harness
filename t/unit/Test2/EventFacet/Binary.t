use Test2::V0 -target => 'Test2::EventFacet::Binary';

subtest 'is_list returns true' => sub {
    is(CLASS->is_list, 1, "is_list() returns 1");
    # Also works on instances
    my $f = CLASS->new(data => 'abc', filename => 'test.png');
    is($f->is_list, 1, "is_list() on instance returns 1");
};

subtest 'isa Test2::EventFacet' => sub {
    my $f = CLASS->new;
    isa_ok($f, 'Test2::EventFacet');
};

subtest 'data accessor' => sub {
    my $f = CLASS->new(data => 'SGVsbG8=');
    is($f->data, 'SGVsbG8=', "data getter");
};

subtest 'filename accessor' => sub {
    my $f = CLASS->new(filename => 'screenshot.png');
    is($f->filename, 'screenshot.png', "filename getter");
};

subtest 'is_image accessor' => sub {
    my $f_img  = CLASS->new(is_image => 1);
    my $f_data = CLASS->new(is_image => 0);

    is($f_img->is_image,  1, "is_image true");
    is($f_data->is_image, 0, "is_image false");
};

subtest 'all fields set together' => sub {
    my $f = CLASS->new(
        data      => 'base64data',
        filename  => 'capture.jpg',
        is_image  => 1,
    );
    is($f->data,     'base64data',  "data");
    is($f->filename, 'capture.jpg', "filename");
    is($f->is_image, 1,             "is_image");
};

done_testing;
