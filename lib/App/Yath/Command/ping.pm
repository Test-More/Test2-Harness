package App::Yath::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000000';

use App::Yath::Client;

use Time::HiRes qw/sleep time/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPC',
    'App::Yath::Options::Yath',
);

sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary  { "Ping the test runner" }

sub description {
    return <<"    EOT";
This command can be used to test communication with a persistent runner
    EOT
}

sub run {
    my $self = shift;

    my $client = App::Yath::Client->new(settings => $self->{+SETTINGS});

    while (1) {
        my $start = time;
        print "\n=== ping ===\n";
        my $res = $client->ping();

        print "=== $res ===\n";
        print "=== " . sprintf("%-02.4f", time - $start) . " ===\n";

        sleep 4;
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::ping - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

