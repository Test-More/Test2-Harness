package XXX;
use strict;
use warnings;

use Test2::Harness::Preload;

stage foo => sub {
    eager;

    preload "Scalar::Util";

    preload sub {
        1;
        #print "Preload sub ran!\n";
    };

    stage bar => sub {
        preload "List::Util";
        1;
    };

    stage theone => sub {
        preload "Data::Dumper";

        preload 'YYY';

        #pre_fork(sub { print STDERR "\n!!! PREFORK! $$ $0\n" });
        #post_fork(sub { print STDERR "\n!!! POSTFORK! $$ $0\n" });
        #pre_launch(sub { print STDERR "\n!!! PRELAUNCH! $$ $0\n" });

        default();
    };

    1;
};

stage baz => sub {
    1
};
