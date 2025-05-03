package Test2::Harness::IPC::Protocol::AtomicPipe::Connection;
use strict;
use warnings;

our $VERSION = '2.000005';

use IO::Select;
use Atomic::Pipe;

use Carp qw/confess croak/;
use Errno qw/EINTR/;
use Time::HiRes qw/sleep/;
use Scalar::Util qw/weaken blessed/;

use Test2::Harness::IPC::Util qw/check_pipe ipc_warn pid_is_running/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_json/;

use Test2::Harness::Instance::Message;
use Test2::Harness::Instance::Request;
use Test2::Harness::Instance::Response;

use parent 'Test2::Harness::IPC::Connection';
use Test2::Harness::Util::HashBase qw{
    <active
    <fifo
    +pipe
    <reader
    <requests
    <peer_pid
    <deactivated
};

my %CACHE;

sub init {
    my $self = shift;

    weaken($self->{+READER});
    $self->{+PROTOCOL} //= 'Test2::Harness::IPC::Protocol::AtomicPipe';

    $self->SUPER::init();

    my $fifo = $self->{+FIFO} or croak "'fifo' is a required attribute";

    if ($CACHE{$fifo}) {
        $self->{+PIPE} = $CACHE{$fifo};
    }

    $self->{+ACTIVE} = 1;
}

sub pipe {
    my $self = shift;
    return $self->{+PIPE} if $self->{+PIPE};

    my $fifo = $self->{+FIFO} or die "No fifo?!";

    my $valid_fifo = 0;
    for (1 .. 10) {
        $valid_fifo ||= -e $fifo && -p $fifo;
        last if $valid_fifo;
        sleep 0.1;
    }

    confess "'$fifo' is not a valid fifo" unless $valid_fifo;

    my $p = Atomic::Pipe->write_fifo($fifo);
    $p->resize_or_max($p->max_size) if $p->max_size;

    $self->{+PIPE} = $p;

    $CACHE{$fifo} = $p;
    weaken($CACHE{$fifo});

    return $p;
}

sub handles_for_select { $_[0]->{+READER}->handles_for_select }
sub callback           { $_[0]->{+READER}->callback }

sub health_check {
    my $self = shift;

    return 0 unless $self->{+ACTIVE};

    my $ok = 1;
    $ok &&= check_pipe($self->pipe, $self->{+FIFO});
    $ok &&= pid_is_running($self->{+PEER_PID}) if $self->{+PEER_PID};

    return 1 if $ok;

    $self->terminate();

    return 0;
}

sub expired {
    my $self = shift;

    return 0 if $self->{+ACTIVE} && $self->health_check;
    return 1 unless keys %{$self->{+REQUESTS}};

    $self->{+DEACTIVATED} //= time;

    my $delta = time - $self->{+DEACTIVATED};

    # If we have not had a response in 60 seconds we assume the connection died.
    return 1 if $delta > 60;

    return 0;
}


sub send_message {
    my $self = shift;
    my ($msg) = @_;

    croak "Disconnected pipe" unless $self->{+ACTIVE};

    $msg = Test2::Harness::Instance::Message->new(%$msg)
        unless blessed($msg) && $msg->isa('Test2::Harness::Instance::Message');

    $msg->set_ipc_meta({return_fifo => $self->{+READER}->read_file});

    my $json = encode_json($msg);

    my $ok;
    while (1) {
        $! = 0;
        last if eval { local $SIG{PIPE} = 'IGNORE'; $self->pipe->write_message($json); 1 };
        next if $! == EINTR;
        $self->terminate();
        croak "Disconnected pipe";
    }

    return $json;
}

sub send_request {
    my $self = shift;
    my ($api_call, $args, %params) = @_;

    croak "Communication is currently one-way, (did you forget to call start() on the main pipe object?)" unless $self->{+READER} && $self->{+READER}->active;

    my $id = gen_uuid();

    my $req = Test2::Harness::Instance::Request->new(
        request_id     => $id,
        api_call       => $api_call,
        args           => $args,
        do_not_respond => $params{do_not_respond},
    );

    my $json = $self->send_message($req);

    $self->{+REQUESTS}->{$id} = undef
        unless $req->do_not_respond;

    return $params{return_request} ? $req : $id;
}

sub get_response {
    my $self = shift;
    my ($id, %params) = @_;

    croak "Invalid request id $id" unless exists $self->{+REQUESTS}->{$id};

    my $blocking = $params{blocking} //= 0;
    my $timeout  = $params{timeout};

    while (1) {
        return delete $self->{+REQUESTS}->{$id}
            if defined $self->{+REQUESTS}->{$id};

        return unless $self->{+READER} && $self->{+READER}->active;

        my $new = $self->{+READER}->_read_messages(%params);
        croak "Connection error: $!" if $new < 0;
        next if $new;

        return unless $blocking || defined($timeout);
    }
}

sub send_response {
    my $self = shift;
    my ($req, $res) = @_;

    $res = Test2::Harness::Instance::Response->new(%$req, response_id => $req->request_id)
        unless blessed($res) && $res->isa('Test2::Harness::Instance::Response');

    return $self->send_message($res);
}

sub handle_response {
    my $self = shift;
    my ($res) = @_;

    my $id = $res->response_id;

    croak "'$id' is not a valid request/response id" unless exists $self->{+REQUESTS}->{$id};
    croak "'$id' already has a response" if defined $self->{+REQUESTS}->{$id};

    $self->{+REQUESTS}->{$id} //= $res;
}

sub terminate {
    my $self = shift;

    $self->{+ACTIVE} = 0;
    $self->{+DEACTIVATED} = time;

    delete $self->{+PIPE};
    delete $self->{+READER};
}

sub TO_JSON {
    my $self = shift;

    return {
        protocol => $self->protocol,
        connect  => [$self->{+FIFO}, undef],
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::IPC::Protocol::AtomicPipe::Connection - FIXME

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

