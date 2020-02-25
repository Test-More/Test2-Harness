package App::Yath::Command::projects;
use strict;
use warnings;

our $VERSION = '0.999005';

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase;

sub summary { "Run tests for multiple projects" }
sub cli_args { "[--] projects_dir [::] [arguments to test scripts]" }

sub description {
    return <<"    EOT";
This command will run all the tests for each project within a parent directory.
    EOT
}

sub finder_args {(multi_project => 1)}

1;

__END__

=head1 POD IS AUTO-GENERATED

