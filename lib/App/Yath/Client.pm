package App::Yath::Client;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness::IPC::Protocol;

use parent 'Test2::Harness';
use Test2::Harness::Util::HashBase qw{
    <settings
    +ipc +connection
};

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS} or croak "'settings' is a required attribute";
    croak "'ipc' is not set, and there is no 'ipc' category in the settings"
        unless $self->{+IPC} or $settings->ipc;

    $self->ipc;

    $self->SUPER::init();
}

sub ipc_text {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    my $ipc_s = App::Yath::Options::IPC->vivify_ipc($settings);
    use Data::Dumper;
    print Dumper($ipc_s);

    my $out = "Harness instance pid " . $ipc_s->{peer_pid};
    if (my $prot = $ipc_s->{protocol}) {
        $prot =~ s/^Test2::Harness::IPC::Protocol:://;
        $out .= " $prot";

        if (my $addr = $ipc_s->{address}) {
            $addr = File::Spec->abs2rel($addr) if -e $addr;
            $out .= " $addr";

            if (my $port = $ipc_s->{port}) {
                $out .= ":$port";
            }
        }
    }

    return $out;
}

sub ipc {
    my $self = shift;

    return $self->{+IPC} if $self->{+IPC};

    my $settings = $self->{+SETTINGS};
    croak "No 'ipc' category in settings" unless $settings->ipc;
    my $ipc_s = App::Yath::Options::IPC->vivify_ipc($settings);

    return $self->{+IPC} = Test2::Harness::IPC::Protocol->new(protocol => $ipc_s->{protocol}, peer_pid => $ipc_s->{peer_pid});
}

sub connect {
    my $self = shift;

    return $self->{+CONNECTION} if $self->{+CONNECTION};

    my $settings = $self->{+SETTINGS};
    croak "No 'ipc' category in settings" unless $settings->ipc;
    my $ipc_s = App::Yath::Options::IPC->vivify_ipc($settings);

    return $self->{+CONNECTION} = $self->ipc->connect($ipc_s->{address}, $ipc_s->{port}, peer_pid => $ipc_s->{peer_pid});
}

1;
