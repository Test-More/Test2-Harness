use Test2::V0;

use Test2::Harness2::Util::JSON qw/encode_json_file decode_json_file/;

subtest 'encode_json_file returns a plain path by default' => sub {
    my $path = encode_json_file({a => 1});
    ok(!ref($path), "default return is a plain string, not a ref");
    ok(-f $path, "temp file exists");
    unlink $path;
};

subtest 'encode_json_file with guard => 1 returns a guard that stringifies to the path' => sub {
    my $guard = encode_json_file({a => 1}, guard => 1);
    my $path  = "$guard";

    ok(defined $path && length $path, "guard stringifies to a non-empty path");
    ok(-f $path,                      "temp file exists while guard is in scope");
};

subtest 'guard auto-unlinks file on scope exit' => sub {
    my $path;
    {
        my $guard = encode_json_file({b => 2}, guard => 1);
        $path = "$guard";
        ok(-f $path, "file exists while guard is in scope");
    }
    ok(!-f $path, "file auto-deleted when guard goes out of scope");
};

subtest 'guard dismiss cancels auto-unlink' => sub {
    my $path;
    {
        my $guard = encode_json_file({c => 3}, guard => 1);
        $path = "$guard";
        ok(-f $path, "file exists while guard is in scope");
        $guard->dismiss;
    }
    ok(-f $path, "file still exists after dismissed guard goes out of scope");
    unlink $path;
    ok(!-f $path, "cleanup: manually unlinked after dismiss");
};

subtest 'guard roundtrip via decode_json_file' => sub {
    my $data  = {key => 'value', nums => [1, 2, 3]};
    my $guard = encode_json_file($data, guard => 1);
    my $path  = "$guard";

    ok(-f $path, "temp file exists");
    my $decoded = decode_json_file($path);
    is($decoded, $data, "data roundtrips correctly");

    $guard->dismiss;
    unlink $path;
};

subtest 'guard unlink is idempotent when file already gone' => sub {
    my $path;
    my $guard = encode_json_file({d => 4}, guard => 1);
    $path = "$guard";
    unlink $path;
    ok(!-f $path, "file manually removed before guard goes out of scope");
    # Guard DESTROY should not die when the file is already gone
    ok(lives { undef $guard }, "guard DESTROY does not die when file is already unlinked");
};

done_testing;
