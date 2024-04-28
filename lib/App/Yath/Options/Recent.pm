package App::Yath::Options::Recent;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

option_group {group => 'recent', prefix => 'recent', category => "Recent Options"} => sub {
    option max => (
        type => 'Scalar',
        long_examples => [' 10'],
        default => 10,
        description => 'Max number of recent runs to show',
    );
};

1;
