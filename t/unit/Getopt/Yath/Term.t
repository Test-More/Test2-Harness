use Test2::V0 -target => 'Getopt::Yath::Term';

use Getopt::Yath::Term qw{
    color
    USE_COLOR
    term_size
    fit_to_width
};

imported_ok qw{
    color
    USE_COLOR
    term_size
    fit_to_width
};

subtest fit_to_width => sub {
    is(fit_to_width(" ", "hello there", width => 100), "hello there",  "No change for short string");
    is(fit_to_width(" ", "hello there", width => 2),   "hello\nthere", "Split across multiple lines");

    is(
        fit_to_width(" ", "hello there, this is a longer string that needs splitting.", width => 20),
        "hello there, this is\na longer string that\nneeds splitting.",
        "Split across multiple lines"
    );

    is(
        fit_to_width(" ", ["hello there", "this is a", "longer string that", "needs no splitting."], width => 100),
        "hello there this is a longer string that needs no splitting.",
        "Split across multiple lines"
    );

    is(
        fit_to_width(" ", ["hello there", "this is a", "longer string that", "needs splitting."], width => 50),
        "hello there this is a longer string that\nneeds splitting.",
        "Split across multiple lines"
    );
};

subtest color => sub {
    if ($INC{'Term/ANSIColor.pm'}) {
        ok(USE_COLOR, "Color enabled");
        is(color('blue'), Term::ANSIColor::color('blue'), "Delegates to Term::ANSIColor");
    }
    else {
        ok(!USE_COLOR, "Color disabled");
        is(color('blue'), '', "No Color");
    }
};

subtest term_size => sub {
    local $ENV{TABLE_TERM_SIZE} = 100;
    is(term_size(), 100, "Got the terminal size");
};

done_testing;
