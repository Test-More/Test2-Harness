package Test2::Harness::IPC::Protocol::AtomicPipe;
use strict;
use warnings;

our $VERSION = '2.000005';

use Test2::Harness::IPC::Protocol::AtomicPipe::Connection;

use Atomic::Pipe;

use Carp qw/croak confess/;
use Errno qw/EINTR/;
use POSIX qw/mkfifo/;
use Scalar::Util qw/blessed/;
use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::IPC::Util qw/check_pipe ipc_warn pid_is_running/;
use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Harness::Instance::Message;
use Test2::Harness::Instance::Request;
use Test2::Harness::Instance::Response;

use parent 'Test2::Harness::IPC::Protocol';
use Test2::Harness::Util::HashBase qw{
    <active
    <read_file
    <read_pipe

    <messages
    <requests

    <peer_pid
    <my_pid

    +connections

    <wait_time
};

sub callback {
    my $self = shift;

    croak "Inactive pipe" unless $self->{+ACTIVE};

    return {
        protocol => $self->protocol,
        connect  => [$self->{+READ_FILE}, undef],
    };
}

sub get_address {
    my $class = shift;
    my ($file) = @_;
    return $file;
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+WAIT_TIME} //= 0.2;

    $self->{+ACTIVE} = 0;
}

sub connections {
    my $self = shift;
    return values %{$self->{+CONNECTIONS} // {}};
}

sub handles_for_select {
    my $self = shift;
    $self->health_check();
    return unless $self->{+ACTIVE};
    return ($self->{+READ_PIPE}->rh);
}

sub health_check {
    my $self = shift;

    for my $con (values %{$self->{+CONNECTIONS}}) {
        delete $self->{+CONNECTIONS}->{$con->fifo} if $con->expired;
    }

    my $ok = $self->{+ACTIVE};
    $ok &&= check_pipe($self->{+READ_PIPE});
    $ok &&= pid_is_running($self->{+PEER_PID}) if $self->{+PEER_PID};
    return 1 if $ok;

    $self->terminate();

    return 0;
}

sub start {
    my $self = shift;
    my ($file) = @_;

    croak "Pipe is already active" if $self->{+ACTIVE};

    croak "'file' is a required argument" unless $file;

    unless (-p $file) {
        mkfifo($file, 0700) or die "Failed to make fifo '$file': $!";
    }

    my $p = Atomic::Pipe->read_fifo($file);
    $p->blocking(0);
    $p->resize_or_max($p->max_size) if $p->max_size;

    $self->{+READ_FILE}   = $file;
    $self->{+READ_PIPE}   = $p;
    $self->{+MESSAGES}    = [];
    $self->{+REQUESTS}    = [];
    $self->{+CONNECTIONS} = {};
    $self->{+MY_PID}      = $$;
    $self->{+ACTIVE}      = 1;
}

sub connect {
    my $self = shift;
    my ($fifo, $port, %options) = @_;

    $port //= $$;

    $options{auto_start} //= 1;

    if($options{auto_start} && !$self->{+ACTIVE}) {
        my $listen = "${fifo}.${port}";
        croak "File '$listen' already exists " if -e $listen;
        $self->start($listen);
    }

    my $con = Test2::Harness::IPC::Protocol::AtomicPipe::Connection->new(fifo => $fifo, reader => $self, protocol => $self->protocol);
    $self->{+CONNECTIONS}->{$fifo} = $con;

    return $con;
}

sub send_message {
    my $self = shift;
    my ($msg) = @_;

    $msg = Test2::Harness::Instance::Message->new(%$msg)
        unless blessed($msg) && $msg->isa('Test2::Harness::Instance::Message');

    for my $con (values %{$self->{+CONNECTIONS}}) {
        next if eval { $con->send_message($msg); 1 };
        ipc_warn(error => $@);
        delete $self->{+CONNECTIONS}->{$con->fifo} if $con->expired;
    }

    return;
}

sub have_messages { 0 + @{$_[0]->{+MESSAGES}} }
sub get_message {
    my $self = shift;
    my %params = @_;

    my $blocking = $params{blocking} //= 0;
    my $timeout  = $params{timeout};

    while (1) {
        return shift(@{$self->{+MESSAGES}}) if @{$self->{+MESSAGES}};
        my $count = $self->_read_messages(%params);
        return if $count < 0;
        next if $count;
        return unless $blocking && !$timeout;
    }
}

sub have_requests { 0 + @{$_[0]->{+REQUESTS}} }
sub get_request {
    my $self = shift;
    my %params = @_;

    my $blocking = $params{blocking} //= 0;

    while (1) {
        while (1) {
            last if @{$self->{+REQUESTS}};
            my $count = $self->_read_messages(%params);
            return if $count < 0;
            next if $count;
            return unless $blocking;
        }

        my $req = shift @{$self->{+REQUESTS}};

        unless ($req->do_not_respond) {
            my $con;
            unless (eval { $con = $self->connection_from_message($req); 1 }) {
                ipc_warn(error => $@, request => $req);
                return unless $blocking;
            }

            $req->set_connection($con);
        }

        return $req;
    }
}

sub send_response {
    my $self = shift;
    my ($req, $res) = @_;

    my $con = $self->connection_from_message($req);
    return $con->send_response($req, $res);
}

sub _read_messages {
    my $self = shift;
    my %params = @_;

    confess "Called from wrong process!" unless $$ == $self->{+MY_PID};

    # Do not default timeout to wait_time, they are different thing
    my $timeout  = $params{timeout};
    my $blocking = $params{blocking} // 0;

    return $self->__read_messages() unless $blocking;

    my $ios;
    while (1) {
        return -1 unless $self->health_check;

        my $count = $self->__read_messages();
        return $count if $count;

        $ios //= IO::Select->new([$self->handles_for_select]);

        $! = 0;
        my @h = $ios->can_read($timeout // $self->{+WAIT_TIME});
        next if @h;
        next if $! == EINTR;
        return -1 if $!;
        return 0 if $timeout;
    }
}

sub __read_messages {
    my $self = shift;

    return -1 unless $self->{+ACTIVE};

    my $count = 0;

    while (1) {
        $! = 0;
        my $json = $self->{+READ_PIPE}->read_message;
        next if !$json && $! == EINTR;
        last unless $json;

        my $msg;
        unless (eval { $msg = decode_json($json); 1 }) {
            ipc_warn(error => $@, input_json => $json, input => $msg);
            next;
        }

        $count++;

        if (my $class = $msg->{class}) {
            require(mod2file($class));
            $msg = $class->new($msg);
        }
        else {
            ipc_warn(input => $msg, error => 'No class found for message');
            next;
        }

        my $ipc_meta = $msg->ipc_meta;

        if ($msg->isa('Test2::Harness::Instance::Response')) {
            my $con = $self->connection_from_meta($ipc_meta);
            $con->handle_response($msg);
        }
        elsif ($msg->isa('Test2::Harness::Instance::Request')) {
            push @{$self->{+REQUESTS}} => $msg;
        }
        else {
            if ($msg->terminate && $ipc_meta && $ipc_meta->{return_fifo}) {
                my $fifo = $ipc_meta->{return_fifo};
                delete $self->{+CONNECTIONS}->{$fifo};
            }

            push @{$self->{+MESSAGES}} => $msg;
        }
    }

    $! = 0;
    return $count;
}

sub connection_from_message {
    my $self = shift;
    my ($msg) = @_;

    my $ipc_meta = $msg->ipc_meta or confess "Message did not provide 'return_fifo'";

    return $self->connection_from_meta($ipc_meta);
}

sub connection_from_meta {
    my $self = shift;
    my ($meta) = @_;

    my $fifo = $meta->{return_fifo} or confess "Message did not provide 'return_fifo'";
    return $self->{+CONNECTIONS}->{$fifo} //= Test2::Harness::IPC::Protocol::AtomicPipe::Connection->new(fifo => $fifo, reader => $self);
}

sub refuse_new_connections {
    my $self = shift;

    return unless $$ == $self->{+MY_PID};

    unlink($self->{+READ_FILE}) if -e $self->{+READ_FILE};
}

sub terminate {
    my $self = shift;

    return if $self->{+MY_PID} && $$ != $self->{+MY_PID};

    return unless $self->{+ACTIVE};
    unlink($self->{+READ_FILE}) if -e $self->{+READ_FILE};

    $self->{+ACTIVE} = 0;
}

sub TO_JSON { shift->callback }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::IPC::Protocol::AtomicPipe - FIXME

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


=pod

=cut POD NEEDS AUDIT

