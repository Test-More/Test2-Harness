package App::Yath::Options::Term;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

option_group {group => 'term', category => "Terminal Options"} => sub {
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

    option term_width => (
        type          => 'Scalar',
        field         => 'width',
        alt           => ['term-size'],
        description   => 'Alternative to setting $TABLE_TERM_SIZE. Setting this will override the terminal width detection to the number of characters specified.',
        long_examples => [' 80', ' 200'],
        set_env_vars  => ['TABLE_TERM_SIZE'],
        from_env_vars => ['TABLE_TERM_SIZE'],
    );
};

option_post_process sub {
    my ($options, $state) = @_;
    my $settings = $state->{settings};

    my $term = $settings->term;

    if ($settings->check_group('tests')) {
        my $tests = $settings->tests;
        $tests->env_vars->{TABLE_TERM_SIZE} = $term->width if defined $term->width;
    }
};

1;
