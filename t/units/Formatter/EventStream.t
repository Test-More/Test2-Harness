use Test2::Bundle::Extended -target => 'Test2::Formatter::EventStream';

my $stdout = "";
my $one;
{
    open(my $fh, '>', \$stdout) or die "could not open fake STDOUT";
    local *STDOUT = $fh;
    $one = Test2::Formatter::EventStream->new(encoding => 'utf8', fh => $fh);
}

isa_ok($one, $CLASS);

$one->encoding('utf8');

is($one->hide_buffered, 0, "do not hide buffered events");

my $ok = Test2::Event::Ok->new(
    name => 'hi',
    pass => 1,
    trace => Test2::Util::Trace->new(frame => [__PACKAGE__, __FILE__, __LINE__])
);
$one->write($ok, 5);
$one->write($ok, 6);

is(
    [split /\n/, $stdout],
    [
        "T2_FORMATTER: EventStream", # Announcement
        "T2_ENCODING: utf8", # Initially set
        "T2_ENCODING: utf8", # Manually set again
        match qr/^T2_EVENT: \{.*"__PACKAGE__":"Test2::Event::Ok".*\}/,
        match qr/^T2_EVENT: \{.*"__PACKAGE__":"Test2::Event::Ok".*\}/,
    ],
    "Got events",
) or diag $stdout;

done_testing;
