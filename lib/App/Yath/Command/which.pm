package App::Yath::Command::which;
use strict;
use warnings;

our $VERSION = '1.000080';

use App::Yath::Util qw/find_pfile/;

use Test2::Harness::Util::File::JSON;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary  { "Locate the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This will tell you about any persistent runners it can find.
    EOT
}

sub run {
    my $self = shift;

    my $pfile = find_pfile($self->settings);

    unless ($pfile) {
        print "\nNo persistent harness was found for the current path.\n\n";
        return 0;
    }

    print "\nFound: $pfile\n";
    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
    print "  PID: $data->{pid}\n";
    print "  Dir: $data->{dir}\n";
    print "\n";

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

