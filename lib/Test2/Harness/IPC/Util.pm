package Test2::Harness::IPC::Util;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak confess longmess/;
use Errno qw/ESRCH EINTR/;
use Config qw/%Config/;
use Time::HiRes qw/time sleep/;
use Scalar::Util qw/blessed/;
use Data::Dumper qw/Dumper/;

use POSIX();
use IO::Select();

use Test2::Harness::Util::JSON qw/encode_pretty_json encode_json encode_json_file/;
use Test2::Harness::Util qw/mod2file parse_exit/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    USE_P_GROUPS
    swap_io
    pid_is_running
    check_pipe
    ipc_warn
    ipc_connect
    ipc_loop

    inflate

    set_procname

    start_process
    start_collected_process
};

BEGIN {
    if ($Config{'d_setpgrp'}) {
        *USE_P_GROUPS = sub() { 1 };
    }
    else {
        *USE_P_GROUPS = sub() { 0 };
    }
}

sub set_procname {
    my %params = @_;

    my $prefix = $params{prefix} // $ENV{T2_HARNESS_PROC_PREFIX} // 'Test2-Harness';
    my $append = $params{append} // [];
    my $set    = $params{set}    // [];

    $append = [$append] unless ref($append);
    $set    = [$set]    unless ref($set);

    my $name = join('-', (@$set ? @$set : $0), @$append);

    $name = "${prefix}-${name}" unless $name =~ m/^\Q$prefix\E-/;

    $0 = $name;
}

sub inflate {
    my ($ref, $fallback_class) = @_;

    return unless $ref;
    return $ref if blessed($ref);

    my $class = $ref->{class} // $fallback_class // croak "No class to inflate, provide a 'class' key or as second argument to inflate()";
    require(mod2file($class));

    $_[0] = $class->new($ref);
}

sub pid_is_running {
    my ($pid) = @_;

    confess "A pid is required" unless $pid;

    local $!;

    return 1 if kill(0, $pid); # Running and we have perms
    return 0 if $! == ESRCH;   # Does not exist (not running)
    return -1;                 # Running, but not ours
}

sub swap_io {
    my ($fh, $to, $die, $mode) = @_;

    $die ||= sub {
        my @caller = caller;
        my @caller2 = caller(1);
        die("$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2], ${ \__FILE__ } line ${ \__LINE__ }).\n");
    };

    my $orig_fd;
    if (ref($fh) eq 'ARRAY') {
        ($orig_fd, $fh) = @$fh;
    }
    else {
        $orig_fd = fileno($fh);
    }

    $die->("Could not get original fd ($fh)") unless defined $orig_fd;

    if (ref($to)) {
        $mode //= $orig_fd ? '>&' : '<&';
        open($fh, $mode, $to) or $die->("Could not redirect output: $!");
    }
    else {
        $mode //= $orig_fd ? '>' : '<';
        open($fh, $mode, $to) or $die->("Could not redirect output to '$to': $!");
    }

    return if fileno($fh) == $orig_fd;

    $die->("New handle does not have the desired fd!");
}

sub start_collected_process {
    my %params = @_;

    my $post_fork = delete $params{post_fork};

    my %seen;
    my $pid = start_process(
        [
            $^X,                                                             # Call current perl
            (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @INC),          # Use the dev libs specified
            '-mTest2::Harness::Collector',                                   # Load Collector
            '-e' => 'exit(Test2::Harness::Collector->collect($ARGV[0]))',    # Run it.
            encode_json_file(\%params),                                      # json data for what to do
        ],
        $post_fork,
    );

    return $pid unless $params{setsid};

    local $? = 0;
    my $check = waitpid($pid, 0);
    my $exit  = $?;
    if ($exit || $check != $pid) {
        my $x = parse_exit($exit);
        die "Collector failed ($check vs $pid) (Exit code: $x->{err}, Signal: $x->{sig})";
    }

    return;
}

sub start_process {
    my ($cmd, $post_fork) = @_;

    confess "cmd is required, and must be populated" unless $cmd && @$cmd;
    confess "cmd may not contain undefined values: " . Dumper($cmd) if grep { !defined($_)} @$cmd;

    my $pid = fork // die "Could not fork: $!";
    return $pid if $pid;

    $post_fork->() if $post_fork;

    no warnings;
    my $ok = eval { exec(@$cmd); 1 };
    my $err = $@;
    print STDERR longmess("Failed to exec " . join(' ', @$cmd) . " . ($!) $@\n");
    POSIX::_exit(255);
}

sub check_pipe {
    my ($pipe, $file) = @_;

    if ($file) {
        return 0 unless -e $file;
        return 0 unless -p $file;
    }

    return 0 unless $pipe;

    my @h;
    if (blessed($pipe) && $pipe->isa('Atomic::Pipe')) {
        for my $type (qw/rh wh/) {
            my $h = $pipe->$type or next;
            push @h => $h;
        }
    }
    else {
        push @h => $pipe;
    }

    return 0 unless @h;
    for my $h (@h) {
        return 0 unless $h->opened;
        return 0 unless -p $h;
    }

    return 1;
}

sub ipc_connect {
    my ($ipc_data) = @_;

    return unless $ipc_data;

    require Test2::Harness::IPC::Protocol;
    my $ipc = Test2::Harness::IPC::Protocol->new(protocol => $ipc_data->{protocol});
    my $con = $ipc->connect(@{$ipc_data->{connect}});

    return ($ipc, $con);
}

sub ipc_loop {
    my %params = @_;

    my $caller = [caller];
    my $trace = "$caller->[1] line $caller->[2]";

    my $ipcs    = $params{ipcs};
    my $handles = $params{handles};

    croak "'ipcs' or 'handles' or 'apipes' required" unless $ipcs || $handles;

    $ipcs    //= [];
    $handles //= [];

    my $wait_time = $params{wait_time} // 0.2;

    my $iteration_start = $params{iteration_start};
    my $iteration_end   = $params{iteration_end};
    my $end_check       = $params{end_check};

    my $handle_request = $params{handle_request} // sub { ipc_warn(request => $_[0], error => "Got a request, loop does not handle requests at $trace.\n") };
    my $handle_message = $params{handle_message} // sub { ipc_warn(message => $_[0], error => "Got a message, loop does not handle messages at $trace.\n") };

    my $debug = $params{debug};

    my ($int, $term);
    if (my $signal = $params{signals} // $params{quiet_signals}) {
        my $sig_cnt = 0;
        $int = sub {
            $signal->('INT');
            $sig_cnt++;

            if ($sig_cnt >= 5) {
                die "$0: Got $sig_cnt signals, shutting down more forcefully...\n";
            }

            unless ($params{quiet_signals}) {
                print "\n";
                warn "$0: Cought SIGINT, shutting down... (press control+c " . (5 - $sig_cnt) ." more time(s) to be more forceful)\n";
            }
        };

        $term = sub {
            $signal->('TERM');
            $sig_cnt++;

            die "$0: Got SIGTERM, shutting down...\n";
        };
    }

    local $SIG{TERM} = $term if $term;
    local $SIG{INT}  = $int  if $int;

    my $ipc_map;
    my $ios;
    my $reset_ios = sub {
        $ios = IO::Select->new();

        $ipc_map = {};

        for my $set (@$handles) {
            my ($h) = @$set;
            $ios->add($h);
            $ipc_map->{$h} = $set;
            $ipc_map->{$set} = $set;
        }

        for my $ipc (@$ipcs) {
            for my $h ($ipc->handles_for_select) {
                $ios->add($h);
                $ipc_map->{$h}   = $ipc;
                $ipc_map->{$ipc} = $ipc;
            }
        }
    };
    $reset_ios->();

    # This is used to interrupt a select below. The var and ++ are to prevent the sub from being optimized away
    my $sigchild = 0;
    local $SIG{CHLD} = $params{sigchild} // sub { $sigchild++ };

    my $last_ipc_count = 1;
    my $last_health_check = 0;
    my $did_work = 1;

    my $wait_time_is_code = ref($wait_time) eq 'CODE' ? 1 : 0;
    my $get_wait_time = sub {
        my $ready = shift;
        return 0 if $did_work || @$ready;
        return $wait_time unless $wait_time_is_code;
        return $wait_time->();
    };

    IPC_LOOP: while (1) {
        sleep(0.2) if $debug;
        print "$$ $0 - LOOP ($caller->[1] line $caller->[2]): " . sprintf('%-02.4f', time) . "\n" if $debug;

        $did_work++ if $iteration_start && $iteration_start->();

        if (time - $last_health_check > 4) {
            print "Health Check\n" if $debug;
            $last_ipc_count = 0;

            for my $ipc (@$ipcs) {
                next unless $ipc->active;
                $ipc->health_check;
                $last_ipc_count++ if $ipc->active;
            }

            for my $set (@$handles) {
                my ($h, $cb, %params) = @$set;
                my $eof = $params{eof} // sub { eof($h) };
                if ($eof->()) {
                    print "EOF\n" if $debug;
                }
                else {
                    $last_ipc_count++;
                }
            }

            $last_health_check = time;
            print "New IPC Count: $last_ipc_count\n" if $debug;
        }

        # Some handles may already have messages read, which means can_read()
        # might skip these.
        my @ready;
        push @ready => grep { $_->have_requests || $_->have_messages } @$ipcs;
        push @ready => grep { my ($h, $cb, %p) = @{$_}; $p{ready} ? $p{ready}->() : 0 } @$handles;

        while (1) {
            $! = 0;

            # Add any handles that have things to read.
            push @ready => $ios->can_read($get_wait_time->(\@ready));
            last if @ready || $! == 0;

            # If the system call was interrupted it could mean a child process
            # exited, or similar. Just break the loop so we can advance.
            last if $! == EINTR;

            warn((0 + $!) . ": $!");

            $reset_ios->();
            last unless keys %$ipc_map;
        }

        print "Ready: " . @ready . "\n" if $debug;

        $did_work = 0;

        my %seen;
        for my $h (@ready) {
            my $ipc = $ipc_map->{$h} or next;
            next if $seen{$ipc}++;

            if(ref($ipc) eq 'ARRAY') {
                $did_work++ if $ipc->[1]->();
                next;
            }

            while (my $msg = $ipc->get_message) {
                $did_work++;
                $handle_message->($msg);
            }

            while (my $req = $ipc->get_request) {
                $did_work++;

                print "Request ($trace):  " . encode_pretty_json($req) . "\n" if $debug;
                my $res = $handle_request->($req);

                next if $req->do_not_respond;

                print "Response ($trace): " . encode_pretty_json($res) . "\n" if $debug;
                eval { $ipc->send_response($req, $res); 1 } or ipc_warn(ipc_class => ref($ipc), error => $@, request => $req, response => $res);
            }
        }

        $did_work++ if $iteration_end && $iteration_end->();
        print "Did Work: $did_work\n" if $debug;

        # No IPC means nothing to do
        print "IPC Map: " . (keys %$ipc_map) . "\n" if $debug;
        last unless keys %$ipc_map;
        print "IPC Count: $last_ipc_count\n" if $debug;
        last unless $last_ipc_count;

        if ($end_check && $end_check->(did_work => $did_work)) {
            print "End Check TRUE\n" if $debug;
            last;
        }
    }
}

sub ipc_warn {
    my %params;
    if (@_ == 1) {
        %params = %{$_[0]} if defined($_[0]);
    }
    else {
        %params = @_;
    }

    my @caller = caller;

    my $fields = "";

    my %seen;
    for my $see_field ((grep {exists $params{$_}} 'error', 'request', 'response'), keys %params) {
        my $field = $see_field;
        $field =~ s/_json$//;
        next if $seen{$field}++;

        my $value = $params{$field} // $params{"${field}_json"} // '<UNDEFINED>';
        eval { $value = encode_pretty_json($value) } or warn $@ if ref $value;
        chomp($value);

        my $title = ucfirst($field);
        $fields .= "    ==== Start $title ====\n" . $value . "\n    ==== End $title ====\n";
    }

    warn <<"    EOT1" . $fields . <<"    EOT2";

*******************************************************************************
!!                     Unable to handle IPC transaction                      !!
*******************************************************************************
File: $caller[1]
Line: $caller[2]
    EOT1
*******************************************************************************

    EOT2
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::IPC::Util - FIXME

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

