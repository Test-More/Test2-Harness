package App::Yath::Command::queue;
use strict;
use warnings;

use Carp::Always;

our $VERSION = '0.001005';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::Feeder::JSONL;
use Test2::Harness::Run;
use Test2::Harness;

use parent 'App::Yath::CommandShared::Harness';
use Test2::Harness::Util::HashBase;

sub summary { "replay from an event log" }

sub has_runner  { 1 }
sub has_logger  { 1 }
sub has_display { 1 }

sub cli_args { "[--] [test files/dirs] [::] [arguments to test scripts]" }

sub description {
    return <<"    EOT";
    EOT
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::replay - Command to replay a test run from an event log.

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
