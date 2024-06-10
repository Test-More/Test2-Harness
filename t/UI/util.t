use Test2::V0;

use Test2::Harness::UI::Util qw/parse_duration format_duration/;

imported_ok qw/parse_duration format_duration/;

my $fraction = 0.1;
my $second = 10 * $fraction;
my $minute = $second * 60;
my $hour   = $minute * 60;
my $day    = 24 * $hour;

my $raw = 3 * $fraction + 5 * $second + 7 * $minute + 4 * $hour + 2 * $day;
my $human = format_duration($raw);
is(
    $human,
    "02d:04h:07m:05.3000s",
    "Converted duration to human",
);

is(parse_duration($human), number($raw), "Round-Trip");

is(parse_duration("0.5s"), number(0.5), "Just seconds");
is(parse_duration("3m"), number(3 * $minute), "Just minutes");
is(parse_duration("3h"), number(3 * $hour), "Just hours");
is(parse_duration("3d"), number(3 * $day), "Just days");

is(parse_duration(undef), 0, "undef is 0 duration");
is(parse_duration("123.001"), number(123.001), "Decimal format non-duration is preserved");

done_testing;
