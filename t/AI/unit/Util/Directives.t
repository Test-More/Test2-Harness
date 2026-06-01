use Test2::V0;
use v5.38;

use Test2::Harness2::Util::Directives;

# The directive parser turns "# HARNESS2: key values..." lines into a nested
# hash. It is a pure parser: no file scanning, no harness knowledge.

sub parse ($text) {
    return Test2::Harness2::Util::Directives->parse_string($text, comments => ['#']);
}

subtest basic_values => sub {
    my $r = parse(<<'EOT');
# HARNESS2: category isolation
# HARNESS2: duration short
# HARNESS2: conflicts db net
not a directive
EOT

    is($r->{category}, ['isolation'], "single value");
    is($r->{duration}, ['short'], "another single value");
    is($r->{conflicts}, ['db', 'net'], "multiple values on one line");
};

subtest sigils => sub {
    my $r = parse(<<'EOT');
# HARNESS2: feature.fork @off
# HARNESS2: feature.stream @on
EOT

    is($r->{feature}{fork}, [0], "\@off -> 0");
    is($r->{feature}{stream}, [1], "\@on -> 1");
};

subtest dotted_keys => sub {
    my $r = parse("# HARNESS2: timeout.event 60\n# HARNESS2: timeout.postexit 15\n");
    is($r->{timeout}{event}, [60], "dotted key builds subtree");
    is($r->{timeout}{postexit}, [15], "second dotted key in same subtree");
};

subtest quoted_values => sub {
    my $r = parse('# HARNESS2: meta.note "hello there"' . "\n");
    is($r->{meta}{note}, ['hello there'], "quoted value kept as one token");
};

subtest blocks => sub {
    my $r = parse(<<'EOT');
# HARNESS2: conflicts {
# HARNESS2: conflicts }
EOT
    is($r->{conflicts}, [1], "block open/close records a truthy marker");
};

subtest comment_required => sub {
    like(
        dies { Test2::Harness2::Util::Directives->new(comments => []) },
        qr/'comments' must not be empty/,
        "empty comments rejected",
    );
};

subtest malformed => sub {
    like(
        dies { parse("# HARNESS2: BadKey foo\n") },
        qr/malformed key/,
        "uppercase key rejected",
    );
    like(
        dies { parse(qq{# HARNESS2: meta.note "unterminated\n}) },
        qr/unterminated quote/,
        "unterminated quote rejected",
    );
};

done_testing;
