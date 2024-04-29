package App::Yath::Command::do;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath::Command::Test';
use Test2::Harness::Util::HashBase;

sub group { ' main' }

sub summary { "Run tests using 'run' or 'test', same as the default command, but explicit." }
sub cli_args { "[run or test args]" }

sub description {
    return <<"    EOT";
This is the same as running yath without a command, except that it will not
fail on CLI parsing issues that often get mistaken for commands.

If there is a persistent runner then the 'run' command is used, otherwise the
'test' command is used.
    EOT
}

sub run {
    # This file is actually just a stub for the magic of 'do'. Code is not executed.
    die "This should not be reachable";
}


1;

__END__

=head1 POD IS AUTO-GENERATED


