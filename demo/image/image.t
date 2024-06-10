use Test2::V0;
use MIME::Base64 qw/encode_base64/;

ok(1, "pass");

sub {
    my $ctx = context();

    my $file = __FILE__;
    $file =~ s/image\.t$/scribble.png/;
    open(my $fh, '<:raw', $file) or die "Could not open file '$file': $!";
    local $/ = undef;
    my $image_data = <$fh>;

    $ctx->send_ev2(
        assert => {details => 'fail with image', pass => 0},
        info   => [{tag => 'DIAG', details => 'This will fail and have an image', debug => 1}],
        binary => [
            {
                details  => "A scribble!",
                filename => "scribble.png",
                data     => encode_base64($image_data),
                is_image => 1,
            },
        ]
    );

    $ctx->release;
}->();

ok(1, "pass");

done_testing;
