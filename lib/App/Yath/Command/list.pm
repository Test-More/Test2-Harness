package App::Yath::Command::list;
use strict;
use warnings;

our $VERSION = '2.000006';

use Term::Table();
use File::Spec();

use List::Util qw/max/;
use Time::HiRes qw/sleep/;

use App::Yath::IPC;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPCAll',
    'App::Yath::Options::Yath',
);

sub group { 'state' }

sub summary { "List all active local runners, persistent or otherwise" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
List all active local runners, persistent or otherwise.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    my $ipc = App::Yath::IPC->new(settings => $settings);
    my @daemon = $ipc->find(qw/daemon/);
    my @oneoff = $ipc->find(qw/one/);

    unless (@daemon || @oneoff) {
        print "\nNo instances of yath found.\n";
        return 0;
    }

    if (@oneoff) {
        print "\nSingle-run Instances:\n";
        $self->render_ipc($_) for @oneoff;
    }

    if (@daemon) {
        print "\nPersistent (Daemon) Instances:\n";
        $self->render_ipc($_) for @daemon;
    }

    return 0;
}

sub render_ipc {
    my $self = shift;
    my ($ipc) = @_;

    $ipc = {%$ipc};

    $ipc->{address} = File::Spec->abs2rel($ipc->{address}) if $ipc->{address} && -e $ipc->{address};
    $ipc->{file}    = File::Spec->abs2rel($ipc->{file})    if $ipc->{file}    && -e $ipc->{file};

    delete $ipc->{address} if $ipc->{address} && $ipc->{file} && $ipc->{address} eq $ipc->{file};
    $ipc->{ipc_file} //= delete $ipc->{file};

    my $length = 0;
    my @keys;
    my %seen;
    for my $key (qw/ipc_file peer_pid protocol address port/, sort keys %$ipc) {
        next if $seen{$key}++;
        next if $key eq 'type';
        next unless defined $ipc->{$key};
        push @keys => $key;
        $length = max($length, length($key));
    }

    printf("  \%${length}s: %s\n", $_, $ipc->{$_}) for @keys;
    print "\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

