use strict;
use warnings;


use Test2::Bundle::Extended;

use Cwd ();
use File::Basename ();
use lib Cwd::abs_path(File::Basename::dirname(__FILE__) . "/../../../../../lib" );

use Test2::Harness::Util::Scrubber ();

my $facet = {
    'assert' => {
        'details' => "Howdy\0 Howdy Howdy\n",
    },
    'info' => [
        {
            'details' => "\n\x00\n\x{263a}",
        },
    ],
    'trace' => {
        'full_caller' => [
            'Something::Whatever',
            'Frylock.pm',
            '8008',
            'time_machine',
            "\0Yea man we're totally not giving NULs in args\0",
            "maybe",
            "I can't resist a touch at eval line 6969",
            "No cheating on this test",
            "\0\0\0\0",
            '%^H better not have NULs in it',
        ],
    },
    'meta' => {
        'Test::Builder' => {
            'name' => "Assertion totally does not have \0NULs in it",
        },
    },
};
my $expected  = {
    'assert' => {
        'details' => "Howdy Howdy Howdy\n",
    },
    'info' => [
        {
            'details' => "\n\n☺",
        },
    ],
    'trace' => {
        'full_caller' => [
            'Something::Whatever',
            'Frylock.pm',
            '8008',
            'time_machine',
            "Yea man we're totally not giving NULs in args",
            "maybe",
            "I can't resist a touch at eval line 6969",
            "No cheating on this test",
            "",
            '%^H better not have NULs in it',
        ],
    },
    'meta' => {
        'Test::Builder' => {
            'name' => "Assertion totally does not have NULs in it",
        },
    },
};

Test2::Harness::Util::Scrubber::scrub_facet_data($facet);
is( $facet, $expected, "Got expected scrub of facet data" );

done_testing();
