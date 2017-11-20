package Test2::Harness::Run::Runner::ProcMan::Persist;
use strict;
use warnings;

use POSIX ":sys_wait_h";
use Time::HiRes qw/sleep time/;
use Carp qw/croak/;

our $VERSION = '0.001035';

use Test2::Harness::Run::Runner::ProcMan();

use Test2::Harness::Util::File::JSONL();

use parent 'Test2::Harness::Run::Runner::ProcMan';
use Test2::Harness::Util::HashBase qw{
    -dir

    -in -in_file
    -out -out_file

    -signal_ref
    -request_sent

    -pid
    -parent_pid
};

sub init {
    my $self = shift;

    croak "'dir' is a required attribute"
        unless $self->{+DIR};

    croak "'signal_ref' is a required attribute"
        unless $self->{+SIGNAL_REF};

    $self->SUPER::init();

    $self->{+JOBS} = Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE}, use_write_lock => 1);

    $self->{+IN_FILE}  = File::Spec->catfile($self->{+DIR}, 'procman_in.jsonl');
    $self->{+OUT_FILE} = File::Spec->catfile($self->{+DIR}, 'procman_out.jsonl');

    $self->reset_io;
}

sub reset_io {
    my $self = shift;
    my %pos = @_;

    $self->{+IN} = Test2::Harness::Util::File::JSONL->new(name => $self->{+IN_FILE}, use_write_lock => 1);
    $self->{+OUT} = Test2::Harness::Util::File::JSONL->new(name => $self->{+OUT_FILE});

    while(my ($name, $pos) = each %pos) {
        $self->{$name}->seek($pos);
    }
}

sub spawn {
    my $self = shift;

    return $self->{+PID} if $self->{+PID};

    for my $file ($self->{+OUT}, $self->{+IN}) {
        my $fh = $file->open_file('>>');
        print $fh "";
        close($fh);
    }

    $self->{+PARENT_PID} = $$;

    my $pid = fork();
    die "Could not spawn a persistent procman" unless defined $pid;

    $self->reset_io;

    if ($pid) {
        $self->{+PID} = $pid;
        return $pid;
    }

    $0 = 'yath-procman';

    my $handler = sub {
        print STDERR "$$ Procman got signal, exiting...\n";
        exit(0);
    };
    $SIG{TERM} = $handler;
    $SIG{INT}  = $handler;
    $SIG{HUP}  = $handler;

    my $ok = eval { $self->_spawn; 1 };
    my $err = $@;

    $self->{+OUT}->write(undef);

    exit(0) if $ok;

    warn $err;
    exit(255);
}

sub _spawn {
    my $self = shift;

    my $wait_time = $self->{+WAIT_TIME};
    my $in        = $self->{+IN};

    my @reqs;

    my $pcheck = 0;
    until($self->{+QUEUE_ENDED}) {
        if (kill(0, $self->{+PARENT_PID})) {
            $pcheck = undef;
        }
        else {
            $pcheck ||= time;
        }

        die "Parent has vanished, exiting."
            if $pcheck && (time - $pcheck) > 1;

        $self->poll_tasks;

        push @reqs => $in->poll;

        my @keep;
        for my $req (@reqs) {
            return undef unless $req;
            push @keep => $req unless $self->handle_request($req);
        }
        @reqs = @keep;

        return if $self->{+QUEUE_ENDED};
        sleep($wait_time);
    }
}

sub handle_request {
    my $self = shift;
    my ($req) = @_;

    $req->{type} ||= 'NONE PROVIDED';

    if ($req->{type} eq 'next') {
        return $self->req_next($req);
    }
    elsif ($req->{type} eq 'exit') {
        return $self->req_exit($req);
    }

    die "Invalid request type: $req->{type}";
}

sub req_next {
    my $self = shift;
    my ($req) = @_;

    my $pending = $self->{+_PENDING}->{$req->{stage}} or return 0;
    return 0 unless @$pending;
    my $task = $self->fetch_task($pending) or return 0;

    my $cat = $task->{category};
    $self->bump($cat);

    my $out = $self->{+OUT};
    $out->write($task);

    return 1; # Handled!
}

sub req_exit {
    my $self = shift;
    my ($req) = @_;

    my $cat = $req->{category};

    $self->unbump($cat);

    return 1;
}

sub next {
    my $self = shift;
    my ($stage) = @_;

    $self->wait_on_jobs;

    return undef if ${$self->{+SIGNAL_REF}};
    return undef if $self->{+QUEUE_ENDED};

    kill(0, $self->{+PID}) or die "Persistent ProcMan went away ($self->{+PID})!";

    unless ($self->{+REQUEST_SENT}) {
        my $in = $self->{+IN};
        $in->write({type => 'next', stage => $stage});
        $self->{+REQUEST_SENT}++;
    }

    my $found;
    my $out = $self->{+OUT};
    until($found) {
        my @tasks = $out->poll(max => 1);
        last unless @tasks;

        for my $task (@tasks) {
            if (!$task) {
                $self->{+QUEUE_ENDED} = 1;
                last;
            }
            elsif($task->{stage} eq $stage) {
                die "Too many tesks were found" if $found;
                $found = $task;
            }
        }
    }

    $self->{+REQUEST_SENT} = 0 if $found;

    return $found;
}

sub write_exit {
    my $self = shift;
    my %params = @_;

    $self->SUPER::write_exit(@_);

    $self->{+IN}->write({type => 'exit', category => $params{task}->{category}});
}

1;
