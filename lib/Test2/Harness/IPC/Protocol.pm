package Test2::Harness::IPC::Protocol;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;
use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::Util::HashBase qw{
    <protocol
};

sub init {
    my ($self) = @_;

    my $type = blessed($self);

    my $protocol = $self->{+PROTOCOL};
    if ($type eq __PACKAGE__) {
        croak "'protocol' is a required field" unless $protocol;

        require(mod2file($protocol));

        bless($self, $protocol);
        my $init = $protocol->can('init');
        goto &$init;
    }

    $self->{+PROTOCOL} = $protocol //= $type;
}

sub callback { confess "\nProtocol $_[0] does not implement callback()" }

sub handles_for_select { }

sub refuse_new_connections { confess "\nProtocol $_[0] does not implement refuse_new_connections()" }

sub default_port { undef }
sub verify_port  { confess "\nProtocol $_[0] does not use ports (got $_[-1])" if defined $_[-1] }

sub active       { confess "\nProtocol $_[0] does not implement active()" }
sub health_check { confess "\nProtocol $_[0] does not implement health_check()" }

# These both should take the 'address' and 'port' arguments
sub start   { confess "\nProtocol $_[0] does not implement start()" }
sub connect { confess "\nProtocol $_[0] does not implement connect()" }

# Broadcast
sub send_message { confess "\nProtocol $_[0] does not implement send_message()" }
sub get_message  { confess "\nProtocol $_[0] does not implement get_message()" }
sub have_messages { confess "\nProtocol $_[0] does not implement have_messages()" }

sub get_request   { confess "\nProtocol $_[0] does not implement get_request()" }
sub send_response { confess "\nProtocol $_[0] does not implement send_response()" }
sub have_requests { confess "\nProtocol $_[0] does not implement have_requests()" }

sub connections { confess "\nProtocol $_[0] does not implement connections()" }

sub terminate { }

sub DESTROY { $_[0]->terminate() }

1;