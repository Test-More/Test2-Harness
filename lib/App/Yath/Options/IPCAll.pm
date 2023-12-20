package App::Yath::Options::IPCAll;
use strict;
use warnings;
use feature 'state';

our $VERSION = '2.000000';

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPC',
);

option_group {group => 'ipc', category => 'IPC Options'} => sub {
    option non_daemon => (
        name => 'ipc-non-daemon',
        type => 'Bool',
        default => 1,
        description => 'Normally yath commands will only connect to daemons, but some like "resources" can work on non-daemon instances',
    );
};

1;

__END__



