package App::Yath::Options::Term;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

option_group {group => 'term', category => "Terminal Options"} => sub {
    warn "Help does not seem to show what env vars set this?";
    option color => (
        type => 'Bool',
        short => 'c',
        description => "Turn color on, default is true if STDOUT is a TTY.",
        default     => sub { -t STDOUT ? 1 : 0 },
        set_env_vars  => ['YATH_COLOR'],
        from_env_vars => ['YATH_COLOR', 'CLICOLOR_FORCE'],
    );

    option progress => (
        type => 'Bool',
        default => sub { -t STDOUT ? 1 : 0 },
        description => "Toggle progress indicators. On by default if STDOUT is a TTY. You can use --no-progress to disable the 'events seen' counter and buffered event pre-display",
    );

    warn "FIXME make sure env var is set for tests too";
    option term_width => (
        type          => 'Scalar',
        alt           => ['term-size'],
        description   => 'Alternative to setting $TABLE_TERM_SIZE. Setting this will override the terminal width detection to the number of characters specified.',
        long_examples => [' 80', ' 200'],
        set_env_vars  => ['TABLE_TERM_SIZE'],
        from_env_vars => ['TABLE_TERM_SIZE'],
    );
};

1;
