package Test2::Harness::Runner::Persist;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/confess/;
use POSIX ":sys_wait_h";
use Fcntl qw/LOCK_EX LOCK_UN SEEK_SET/;
use Time::HiRes qw/sleep time/;
use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/read_file write_file_atomic write_file open_file parse_exit file2mod/;
use Long::Jump qw/setjump longjump/;

use File::Spec();

use Test2::Harness::Util::Queue();
use Test2::Harness::Runner::Preload();
use Test2::Harness::Runner::DepTracer();
use Test2::Harness::Runner::Run();
use Test2::Harness::Runner::Stage();

use parent 'Test2::Harness::Runner';
use Test2::Harness::Util::HashBase qw{
    -inotify -stats -last_checked
    -signaled
    -pfile
    -root_pid
    -dtrace

    -monitored
    -stage

    -blacklist_file
    -blacklist_lock
    -blacklist

    +end_loop

    +runs +run_queue
};

BEGIN {
    local $@;
    my $inotify = eval { require Linux::Inotify2; 1 };
    if ($inotify) {
        my $MASK = Linux::Inotify2::IN_MODIFY();
        $MASK |= Linux::Inotify2::IN_ATTRIB();
        $MASK |= Linux::Inotify2::IN_DELETE_SELF();
        $MASK |= Linux::Inotify2::IN_MOVE_SELF();

        *USE_INOTIFY = sub() { 1 };
        require constant;
        constant->import(INOTIFY_MASK => $MASK);
    }
    else {
        *USE_INOTIFY = sub() { 0 };
        *INOTIFY_MASK = sub() { 0 };
    }
}

sub stage_fork { confess "stage_fork() is not supported" }

sub init {
    my $self = shift;

    $self->{+DTRACE} ||= Test2::Harness::Runner::DepTracer->new;
    $self->{+ROOT_PID} = $$;

    $self->SUPER::init();

    $self->{+LOCK_FILE} = File::Spec->catfile($self->{+DIR}, 'lock');

    $self->{+STAGE} ||= '-NONE-';

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;
        print STDERR "$$ ($self->{+STAGE}) Runner caught SIG$sig, reloading...\n";
    };
}

sub DESTROY {
    my $self = shift;
    return if $self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP';

    return unless $$ == $self->{+ROOT_PID};

    local ($?, $@, $!);

    my $pfile = $self->{+PFILE} or return;
    return unless -f $pfile;

    print "$$ Deleting $pfile\n";
    unlink($pfile) or warn "Could not delete $pfile: $!\n";
}

sub respawn {
    my $self = shift;

    print "$$ ($self->{+STAGE}) Waiting for currently running jobs to complete before respawning...\n";
    $self->wait(all => 1);

    my $settings = $self->settings;

    exec(
        $^X,
        $settings->yath->script,
        (map { "-D$_" } @{$settings->yath->dev_libs}),
        'runner',
        ref($self),
        $self->{+DIR},
        pfile => $self->{+PFILE},
    );

    warn "Should not get here, respawn failed";
    CORE::exit(1);
}

sub load_blacklist {
    my $self = shift;

    my $bfile = $self->{+BLACKLIST_FILE} ||= File::Spec->catfile($self->{+DIR}, 'BLACKLIST');

    my $blacklist = $self->{+BLACKLIST} ||= {};

    return unless -f $bfile;

    my $fh = open_file($bfile, '<');
    while(my $pkg = <$fh>) {
        chomp($pkg);
        $blacklist->{$pkg} = 1;
    }
}

sub monitor {
    my $self = shift;

    die "$$ ($self->{+STAGE}) monitor already starated!"
        if $self->{+MONITORED} && $self->{+MONITORED} == $$;

    delete $self->{+INOTIFY};
    $self->{+MONITORED} = $$;

    my $dtrace = $self->dtrace;
    my $stats = $self->{+STATS} ||= {};

    return $self->_monitor_inotify() if USE_INOTIFY();
    return $self->_monitor_hardway();
}

sub _monitor_inotify {
    my $self = shift;

    my $dtrace = $self->dtrace;
    my $stats = $self->{+STATS} ||= {};

    my $inotify = $self->{+INOTIFY} //= do {
        my $in = Linux::Inotify2->new;
        $in->blocking(0);
        $in;
    };

    for my $file (keys %{$dtrace->loaded}) {
        $file = $INC{$file} || $file;
        next if $stats->{$file}++;
        next unless -e $file;
        $inotify->watch($file, INOTIFY_MASK());
    }

    return;
}

sub _monitor_hardway {
    my $self = shift;

    my $dtrace = $self->dtrace;
    my $stats  = $self->{+STATS} ||= {};

    for my $file (keys %{$dtrace->loaded}) {
        $file = $INC{$file} || $file;
        next if $stats->{$file};
        next unless -e $file;
        my (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime, $ctime) = stat($file);
        $stats->{$file} = [$mtime, $ctime];
    }

    return;
}

sub check_monitored {
    my $self = shift;

    return $self->{+SIGNAL} if defined $self->{+SIGNAL};

    my $changed = USE_INOTIFY ? $self->_check_monitored_inotify : $self->_check_monitored_hardway;
    return undef unless $changed;

    print "$$ ($self->{+STAGE}) Runner detected a change in one or more preloaded modules, blacklisting changed files and reloading...\n";

    my %CNI = reverse %INC;
    my @todo = map {[file2mod($CNI{$_}), $_]} keys %$changed;

    my $bl = $self->lock_blacklist();

    my $dep_map = $self->dtrace->dep_map;

    my %seen;
    while (@todo) {
        my $set = shift @todo;
        my ($pkg, $full) = @$set;
        my $file = $CNI{$full} || $full;
        next if $seen{$file}++;
        next if $pkg->isa('Test2::Harness::Runner::Preload');
        print $bl "$pkg\n";
        my $next = $dep_map->{$file} or next;
        push @todo => @$next;
    }

    $self->unlock_blacklist();

    return $self->{+SIGNAL} ||= 'HUP';
}


sub _check_monitored_inotify {
    my $self    = shift;
    my $inotify = $self->{+INOTIFY} or return;

    my @todo = $inotify->read or return;

    return {map { ($_->fullname() => 1) } @todo};
}

sub _check_monitored_hardway {
    my $self = shift;

    # Only check once every 2 seconds
    return if $self->{+LAST_CHECKED} && 2 > (time - $self->{+LAST_CHECKED});

    my (%changed, $found);
    for my $file (keys %{$self->{+STATS}}) {
        my (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime, $ctime) = stat($file);
        my $times = $self->{+STATS}->{$file};
        next if $mtime == $times->[0] && $ctime == $times->[1];
        $found++;
        $changed{$file}++;
    }

    $self->{+LAST_CHECKED} = time;

    return unless $found;
    return \%changed;
}

sub lock_blacklist {
    my $self = shift;

    return $self->{+BLACKLIST_LOCK} if $self->{+BLACKLIST_LOCK};

    my $bl = open_file($self->{+BLACKLIST_FILE}, '>>');
    flock($bl, LOCK_EX) or die "Could not lock blacklist: $!";
    seek($bl,2,0);

    return $self->{+BLACKLIST_LOCK} = $bl;
}

sub unlock_blacklist {
    my $self = shift;

    my $bl = delete $self->{+BLACKLIST_LOCK} or return;

    $bl->flush;
    flock($bl, LOCK_UN) or die "Could not unlock blacklist: $!";
    close($bl);

    return;
}

sub stage_should_fork { 0 }

sub stage_start {
    my $self = shift;
    my ($stage) = @_;

    $0 = "yath-runner-$stage";
    $self->{+STAGE} = $stage;
    $self->load_blacklist;

    my $dtrace = $self->dtrace;
    $dtrace->start;

    my $out = $self->SUPER::stage_start(@_);

    $dtrace->stop;

    return $out;
}

sub stage_stop {
    my $self = shift;
    my ($stage) = @_;

    print "$$ ($self->{+STAGE}) Waiting for jobs and child stages to complete before exiting...\n";
    $self->wait(all => 1);
}

sub stage_spawn_map {
    my $self = shift;

    my %spawn;
    my ($root, @children) = @{$self->{+STAGES}};

    my $parent = $root;
    for my $stage (@children) {
        push @{$spawn{$parent}} => $stage;
        $parent = $stage unless $self->SUPER::stage_should_fork($stage);
    }

    return \%spawn;
}

sub stage_loop {
    my $self = shift;

    my $wait_time = $self->{+WAIT_TIME};

    my $dtrace = $self->dtrace;

    my $stage = $self->{+STAGES}->[0];
    my $spawn = $self->stage_spawn_map();

    my $ok = eval { $self->spawn_stage($stage, $spawn); 1 };
    my $err = $@;

    warn $ok ? $err : "Should never get here, spawn_stage() is not supposed to return";
    CORE::exit(1);
}

sub spawn_child_stages {
    my $self = shift;
    my ($list) = @_;
    return unless $list;

    for my $stage (@$list) {
        my $pid = fork;
        unless (defined($pid)) {
            warn "Failed to fork";
            CORE::exit(1);
        }

        # Child;
        return $stage unless $pid;

        my $proc = Test2::Harness::Runner::Stage->new(pid => $pid, name => $stage);
        $self->watch($proc);
    }

    return undef;
}

sub spawn_stage_callback {
    my $self = shift;
    my ($spawn) = @_;

    my $new_stage;
    my $spawn_meth = $self->can('spawn_stage');

    my $do_spawn = sub {
        $self->dtrace->clear_loaded;
        @_ = ($self, $new_stage, $spawn);
        goto &$spawn_meth;
    };

    return (\$new_stage, $do_spawn);
}

sub spawn_stage {
    my $self = shift;
    my ($stage, $spawn) = @_;

    $self->stage_start($stage);

    # If we get 'new_stage' then we are in a child process and need to load the new stage
    my ($new_stage, $spawn_stage) = $self->spawn_stage_callback($spawn);
    goto &$spawn_stage if $$new_stage = $self->spawn_child_stages($spawn->{$stage});

    $self->monitor();
    print "$$ ($self->{+STAGE}) Ready to run tests...\n";

    my ($ok, $err);
    my $jump = setjump 'Test-Runner-Stage' => sub {
        $ok = eval { $self->task_loop($stage); 1 };
        $err = $@;
    };

    # If we are here than a shild stage exited cleanly and we are already in a
    # child stage and need to swap to it.
    goto &$spawn_stage if $jump && ($$new_stage = $jump->[0]);

    $self->stage_stop($stage);
    $self->stage_exit($stage, $ok, $err);
}

sub stage_exit {
    my $self = shift;
    my ($stage, $ok, $err) = @_;

    if ($ok && $stage eq $self->{+STAGES}->[0] && $self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP') {
        $self->respawn;
        warn "Should never get here, respawn failed";
        CORE::exit(1);
    }

    my $sig = $self->{+SIGNAL};
    CORE::exit($self->sig_exit_code($sig)) if $sig && $sig !~ m/^(SIG)?HUP$/i;
    CORE::exit(0) if $ok;

    warn $err;
    CORE::exit(1);
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);

    return unless $proc->isa('Test2::Harness::Runner::Stage');

    my $stage = $proc->name;

    if ($exit != 0) {
        warn "Child stage '$stage' did not exit cleanly ($exit)!\n";
        CORE::exit(1);
    }

    my $pid = fork;
    unless (defined($pid)) {
        warn "Failed to fork";
        CORE::exit(1);
    }

    # Add the replacement process to the watch list
    if ($pid) {
        $self->watch(Test2::Harness::Runner::Stage->new(pid => $pid, name => $stage));
        return;
    }

    # In the child we do the long jump to unwind the stack
    longjump 'Test-Runner-Stage' => $stage;

    warn "Should never get here, failed to restart stage '$stage'";
    CORE::exit(1);
}

sub task_loop {
    my $self = shift;
    my ($stage) = @_;

    while (1) {
        last if $self->end_loop();
        my $run = $self->run($stage) or last;

        my %complete;
        for my $job ($run->jobs->read()) {
            $complete{$job->job_id}->{$job->is_try} = 1;
        }

        while (1) {
            return if $self->end_loop();

            my $task = $self->next($run, $stage);

            # If we have no tasks and no pending jobs then we can be sure we are done
            last unless $task || $self->wait(cat => Test2::Harness::Runner::Job->category);

            next unless $task;

            next if $complete{$task->{job_id}}->{$task->{is_try} // 0};
            $self->run_job($run, $task);
        };

        delete $self->{+RUN};
        write_file_atomic($self->run_stage_complete_file($stage, $run->run_id), time);
    }
}

sub run_stage_complete_file {
    my $self = shift;
    my ($stage, $run_id) = @_;

    return File::Spec->catfile($self->{+DIR}, "${run_id}-${stage}-complete");
}

sub run {
    my $self = shift;
    my ($stage) = @_;

    my $run_queue = $self->{+RUN_QUEUE} //= Test2::Harness::Util::Queue->new(
        file => File::Spec->catfile($self->{+DIR}, 'run_queue.jsonl'),
    );

    my $runs = $self->{+RUNS} //= [];

    while (1) {
        return if $self->end_loop();

        push @$runs => $run_queue->poll();

        if (!@$runs) {
            $self->wait() or sleep($self->{+WAIT_TIME});
            next;
        }

        my $run_data = shift(@$runs)->[-1];
        return undef unless $run_data;

        # This stage+run is already complete, possibly due to a SIGHUP
        next if -f $self->run_stage_complete_file($stage, $run_data->{run_id});

        return $self->{+RUN} = Test2::Harness::Runner::Run->new(
            %$run_data,
            workdir => $self->{+DIR},
        );
    }
}

sub end_loop {
    my $self = shift;
    return $self->{+END_LOOP} if $self->{+END_LOOP};

    return $self->{+END_LOOP} = 1 if $self->{+SIGNAL};
    return $self->{+END_LOOP} = 1 if $self->check_monitored;

    return 0;
}

sub _preload {
    my $self = shift;
    my ($req, $block) = @_;

    $block = $block ? { %$block, %{$self->blacklist} } : { %{$self->blacklist} };

    my $dtrace = $self->dtrace;

    $dtrace->start;
    my $out = $self->SUPER::_preload($req, $block, $dtrace->my_require);
    $dtrace->stop;

    return $out;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Persist - Persistent variant of the test runner.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
