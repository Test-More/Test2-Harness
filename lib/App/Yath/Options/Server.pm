package App::Yath::Options::Server;
use strict;
use warnings;

use Getopt::Yath;

option_group {group => 'server', category => "Server Options"} => sub {
    option ephemeral => (
        type => 'Auto',
        autofill => 'Auto',
        long_examples => ['', '=Auto', '=PostgreSQL', '=MySQL', '=MariaDB', '=SQLite', '=Percona' ],
        description => "Use a temporary 'ephemeral' database that will be destroyed when the server exits.",
        autofill_text => 'If no db type is specified it will use "auto" which will try PostgreSQL first, then MySQL.',
        allowed_values => [qw/Auto PostgreSQL MySQL MariaDB Percona SQLite/],
    );

    option shell => (
        type => 'Bool',
        default => 0,
        description => "Drop into a shell where the server and database env vars are set so that yath commands will use the started server.",
    );

    option daemon => (
        type => 'Bool',
        default => 0,
        description => "Run the server in the background.",
    );

    option single_user => (
        type => 'Bool',
        default => 0,
        description => "When using an ephemeral database you can use this to enable single user mode to avoid login and user credentials.",
    );

    option single_run => (
        type => 'Bool',
        default => 0,
        description => "When using an ephemeral database you can use this to enable single run mode which causes the server to take you directly to the first run.",
    );

    option no_upload => (
        type => 'Bool',
        default => 0,
        description => "When using an ephemeral database you can use this to enable no-upload mode which removes the upload workflow.",
    );

    option email => (
        type => 'Scalar',
        description => "When using an ephemeral database you can use this to set a 'from' email address for email sent from this server.",
    );
};

