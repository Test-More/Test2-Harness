package App::Yath::Command::reload;
use strict;
use warnings;

our $VERSION = '1.000087';

use File::Spec();
use Test2::Harness::Util::File::JSON;

use App::Yath::Util qw/find_pfile/;
use Test2::Harness::Util qw/open_file/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Reload the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This will send a SIGHUP to the persistent runner, forcing it to reload. This
will also clear the blacklist allowing all preloads to load as normal.
    EOT
}

sub run {
    my $self = shift;

    my $pfile = find_pfile($self->settings)
        or die "Could not find a persistent yath running.\n";

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    my $blacklist = File::Spec->catfile($data->{dir}, 'BLACKLIST');
    if (-e $blacklist) {
        print "Deleting module blacklist...\n";
        unlink($blacklist) or warn "Could not delete blacklist file!";
    }

    print "\nSending SIGHUP to $data->{pid}\n\n";
    kill('HUP', $data->{pid}) or die "Could not send signal!\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

