package Test2::Harness::Run::Runner::Persist;
use strict;
use warnings;

use POSIX ":sys_wait_h";
use Fcntl qw/LOCK_EX LOCK_UN SEEK_SET/;
use Time::HiRes qw/sleep time/;
use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/read_file write_file open_file parse_exit/;
use File::Spec;

use Test2::Harness::Util::DepTracer();

our $VERSION = '0.001078';

use parent 'Test2::Harness::Run::Runner';
use Test2::Harness::Util::HashBase qw{
    -inotify -stats -last_checked
    -signaled
    -pfile
    -root_pid
    -dtrace

    -monitor
    -watched
    -stage

    -blacklist_file
    -blacklist
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

sub init {
    my $self = shift;

    $self->{+DTRACE} ||= Test2::Harness::Util::DepTracer->new;
    $self->{+ROOT_PID} = $$;

    $self->load_blacklist;

    $self->SUPER::init();

    $self->{+WAIT_TIME} ||= 0.02;

    $self->{+STAGE} ||= '-NONE-';
}

sub procman {
    my $self = shift;
    return $self->{+_PROCMAN} if $self->{+_PROCMAN};
    return $self->SUPER::procman(
        end_loop_cb => sub { $self->check_watched || $self->check_monitored },
        lock_file => File::Spec->catfile($self->{+DIR}, 'lock'),
    );
}

sub respawn {
    my $self = shift;

    print "$$ ($self->{+STAGE}) Waiting for currently running jobs to complete before respawning...\n";
    my $procman = $self->procman;
    $self->procman->finish();

    exec($self->cmd(pfile => $self->{+PFILE}));
    warn "Should not get here, respawn failed";
    CORE::exit(255);
}

sub handle_signal {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+SIGNAL};

    $self->{+SIGNAL} = $sig;

    if ($sig eq 'HUP') {
        print STDERR "$$ ($self->{+STAGE}) Runner caught SIG$sig, reloading...\n";
        return;
    }

    die "Runner caught SIG$sig. Attempting to shut down cleanly...\n";
}

sub stage_should_fork { 0 }

sub stage_start {
    my $self = shift;
    my ($stage) = @_;

    my $posfile = File::Spec->catfile($self->{+DIR}, "$stage-pos");
    if (-f $posfile) {
        chomp(my $pos = read_file($posfile));
        $self->procman->reset_io(out => $pos);
    }

    my $dtrace = $self->dtrace;
    $dtrace->start;

    my $out = $self->SUPER::stage_start(@_);

    $dtrace->stop;

    return $out;
}

sub stage_stop {
    my $self = shift;
    my ($stage) = @_;

    print "$$ ($self->{+STAGE}) Waiting for currently running jobs to complete before exiting...\n";
    $self->procman->finish;
}

sub check_monitored {
    my $self = shift;

    my $monitor = $self->{+MONITOR} or return;
    my $sig = $self->{+SIGNAL};

    my $reaped = 0;
    foreach my $cs (sort keys %$monitor) {
        my $pid = $monitor->{$cs};
        kill($sig, $pid) or warn "$$ ($self->{+STAGE}) could not singal stage '$cs' pid $pid" if $sig;
        my $check = waitpid($pid, $sig ? 0 : WNOHANG);
        my $exit = $?;
        next unless $check;
        $reaped++;
        die "$$ ($self->{+STAGE}) waitpid error for stage '$cs': $check (expected $pid)" if $check != $pid;
        my $e = parse_exit($exit);
        print "$$ ($self->{+STAGE}) Stage '$cs' has exited (sig: $e->{sig}, err: $e->{err})\n";
        delete $monitor->{$cs};
    }

    return $reaped;
}

sub stage_loop {
    my $self = shift;

    my $wait_time = $self->{+WAIT_TIME};

    my $pman = $self->procman;
    my $dtrace = $self->dtrace;

    my %spawn;
    my ($root, @children) = @{$self->{+STAGES}};

    my $parent = $root;
    for my $stage (@children) {
        if($self->SUPER::stage_should_fork($stage)) {
            push @{$spawn{$parent}->{iso}} => $stage;
        }
        else {
            $spawn{$parent}->{next} = $stage;
            $parent = $stage;
        }
    }

    my $stage = $root;
    STAGE: while ($stage) {
        my $spec = $spawn{$stage} || {};

        $0 = "yath-runner-$stage";
        $self->stage_start($stage);

        my $monitor = $self->{+MONITOR} = {};

        until ($pman->queue_ended) {
            $self->check_watched();
            my $sig = $self->{+SIGNAL};

            print "$$ ($self->{+STAGE}) Waiting for child stages to exit...\n" if $sig && keys %{$monitor};
            $self->check_monitored();

            last if $sig;

            # Spin up any initial or missing iso stages
            for my $iso (@{$spec->{iso}}) {
                next if $monitor->{$iso};

                my ($pid, $runfile) = $self->stage_run_iso($iso);
                return $runfile if $runfile;

                $monitor->{$iso} = $pid;
            }

            my $next = $spec->{next};

            # No children, or children are spawned, do an iteration
            if ((!$next) || $monitor->{$next}) {
                unless($self->{+STAGE} eq $stage) {
                    $self->{+STAGE} = $stage;
                    $self->watch();
                    print "$$ ($self->{+STAGE}) Ready to run tests...\n";
                }
                my $runfile = $self->task_loop($stage);
                return $runfile if $runfile;
                sleep($wait_time);
                next;
            }

            # Spawn the child
            $monitor->{$next} = fork() and next;

            die "Could not fork" unless defined $monitor->{$next};
            $stage = $next;
            $dtrace->clear_loaded;
            next STAGE; # Move to next stage
        }

        $self->stage_stop($stage);

        if ($stage eq $root) {
            $self->respawn if $self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP';
            return undef;
        }

        CORE::exit(0);
    }

    die "Should never get here!";
}

sub stage_run_iso {
    my $self = shift;
    my ($stage) = @_;

    my $pid = fork();
    die "Could not fork" unless defined($pid);
    return ($pid, undef) if $pid;

    delete $self->{+MONITOR};

    my $dtrace = $self->dtrace;

    $dtrace->clear_loaded;
    $0 = "yath-runner-iso-$stage";
    $self->stage_start($stage);
    $self->{+STAGE} = $stage;
    $self->watch();
    print "$$ ($self->{+STAGE}) Ready to run tests...\n";

    my $pman = $self->procman;
    my $wait_time = $self->{+WAIT_TIME};

    until ($pman->queue_ended) {
        $self->check_watched();
        last if $self->{+SIGNAL};
        my $runfile = $self->task_loop($stage);
        return (undef, $runfile) if $runfile;
        sleep($wait_time);
    }

    $self->stage_stop($stage);
    CORE::exit(0);
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

sub watch {
    my $self = shift;

    die "$$ ($self->{+STAGE}) Watch already starated!"
        if $self->{+WATCHED} && $self->{+WATCHED} == $$;

    delete $self->{+INOTIFY};
    $self->{+WATCHED} = $$;

    my $dtrace = $self->dtrace;
    my $stats = $self->{+STATS} ||= {};

    if (USE_INOTIFY()) {
        my $inotify = $self->{+INOTIFY} ||= do {
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
    }
    else {
        for my $file (keys %{$dtrace->loaded}) {
            $file = $INC{$file} || $file;
            next if $stats->{$file};
            next unless -e $file;
            my (undef,undef,undef,undef,undef,undef,undef,undef,undef,$mtime,$ctime) = stat($file);
            $stats->{$file} = [$mtime, $ctime];
        }
    }
}

sub check_watched {
    my $self = shift;

    return $self->{+SIGNAL} if $self->{+SIGNAL};

    my %changed;
    if (USE_INOTIFY()) {
        my $inotify = $self->{+INOTIFY} or return;
        $changed{$_->fullname}++ for $inotify->read;
    }
    else {
        # Only check once every 2 seconds
        return undef if $self->{+LAST_CHECKED} && 2 > (time - $self->{+LAST_CHECKED});

        for my $file (keys %{$self->{+STATS}}) {
            my (undef,undef,undef,undef,undef,undef,undef,undef,undef,$mtime,$ctime) = stat($file);
            my $times = $self->{+STATS}->{$file};
            next if $mtime == $times->[0] && $ctime == $times->[1];
            $changed{$file}++;
        }

        $self->{+LAST_CHECKED} = time;
    }

    return undef unless keys %changed;

    print STDERR "$$ ($self->{+STAGE}) Runner detected a change in one or more preloaded modules, blacklisting changed files and reloading...\n";

    my $dtrace = $self->dtrace;
    my $dep_map = $dtrace->dep_map;

    my %CNI = reverse %INC;
    my @todo = map {[file_to_pkg($CNI{$_}), $_]} keys %changed;

    my $bl = open_file($self->{+BLACKLIST_FILE}, '>>');
    flock($bl, LOCK_EX) or die "Could not lock blacklist: $!";
    seek($bl,2,0);

    my %seen;
    while (@todo) {
        my $set = shift @todo;
        my ($pkg, $full) = @$set;
        my $file = $CNI{$full} || $full;
        next if $seen{$file}++;
        next if $pkg->isa('Test2::Harness::Preload');
        print $bl "$pkg\n";
        my $next = $dep_map->{$file} or next;
        push @todo => @$next;
    }

    $bl->flush;
    flock($bl, LOCK_UN) or die "Could not unlock blacklist: $!";
    close($bl);

    return $self->{+SIGNAL} ||= 'HUP';
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

sub file_to_pkg {
    my $file = shift;
    my $pkg  = $file;
    $pkg =~ s{/}{::}g;
    $pkg =~ s/\..*$//;
    return $pkg;
}

1;

__END__

sub preloads_changed {
    my $self = shift;

    my %changed;
    if (USE_INOTIFY()) {
        my $inotify = $self->{+INOTIFY} or return;
        $changed{$_->fullname}++ for $inotify->read;
    }
    else {
        for my $file (keys %{$self->{+STATS}}) {
            my (undef,undef,undef,undef,undef,undef,undef,undef,undef,$mtime,$ctime) = stat($file);
            my $times = $self->{+STATS}->{$file};
            next if $mtime == $times->[0] && $ctime == $times->[1];
            $changed{$file}++;
        }
    }

    return 0 unless keys %changed;

    my %CNI = reverse %INC;

    for my $full (keys %changed) {
        my $file = $CNI{$full} || $full;
        my $pkg  = file_to_pkg($file);

        my @todo = ($pkg);
        my %seen;
        while(@todo) {
            my $it = shift @todo;
            next if $seen{$it}++;
            $self->{+STATE}->{block_preload}->{$it} = 1 unless $it->isa('Test2::Harness::Preload');
            push @todo => @{$self->{+DEP_MAP}->{$it}} if $self->{+DEP_MAP}->{$it};
        }
    }

    return if $self->{+HUP};
    print STDERR "Runner detected a change in one or more preloaded modules, saving state and reloading...\n";

    return $self->{+HUP} = 1;
}

1;
