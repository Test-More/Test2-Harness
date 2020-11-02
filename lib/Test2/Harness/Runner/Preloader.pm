package Test2::Harness::Runner::Preloader;
use strict;
use warnings;

our $VERSION = '1.000038';

use Carp qw/confess croak/;
use Fcntl qw/LOCK_EX LOCK_UN/;
use Time::HiRes qw/time/;
use Test2::Harness::Util qw/open_file file2mod mod2file lock_file unlock_file/;

use Test2::Harness::Runner::Preloader::Stage;

use File::Spec();

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

use Test2::Harness::Util::HashBase(
    qw{
        <dir
        <preloads
        <done
        <below_threshold

        <inotify <stats <last_checked
        <dtrace

        <staged <started_stages

        <monitor
        <monitored
        <changed

        <blacklist_file
        <blacklist_lock
        <blacklist
    }
);

sub init {
    my $self = shift;

    $self->{+PRELOADS} //= [];

    $self->{+BELOW_THRESHOLD} //= 0;

    return if $self->{+BELOW_THRESHOLD};

    if ($self->{+MONITOR}) {
        require Test2::Harness::Runner::DepTracer;
        $self->{+DTRACE} //= Test2::Harness::Runner::DepTracer->new();

        $self->{+BLACKLIST}      //= {};
        $self->{+BLACKLIST_FILE} //= File::Spec->catfile($self->{+DIR}, 'BLACKLIST');
    }
}

sub stage_check {
    my $self = shift;
    my ($stage) = @_;

    return 0 if $self->{+BELOW_THRESHOLD};

    my $p = $self->{+STAGED} or return 0;
    return 1 if $stage eq 'NOPRELOAD';
    return 1 if $p->stage_lookup->{$stage};
    return 0;
}

sub task_stage {
    my $self = shift;
    my ($file, $wants) = @_;

    return 'default' if $self->{+BELOW_THRESHOLD};
    return 'default' unless $self->{+STAGED};

    return $wants if $wants && $self->stage_check($wants);

    my $stage = $self->{+STAGED}->file_stage($file) // $self->{+STAGED}->default_stage;

    return $stage;
}

sub preload {
    my $self = shift;

    croak "Already preloaded" if $self->{+DONE};

    return 'default' if $self->{+BELOW_THRESHOLD};

    my $preloads = $self->{+PRELOADS} or return 'default';
    return 'default' unless @$preloads;

    require Test2::API;
    Test2::API::test2_start_preload();

    # Not loading blacklist yet because any preloads in this list need to
    # happen regardless of the blacklist.
    if ($self->{+MONITOR}) {
        $self->_monitor_preload($preloads);
    }
    else {
        $self->_preload($preloads);
    }

    $self->{+DONE} = 1;

    return 'default' unless $self->{+STAGED};

    return $self->preload_stages('NOPRELOAD', @{$self->{+STAGED}->stage_list});
}

sub preload_stages {
    my $self = shift;
    my @stages = @_;

    my $name = 'base';
    my @procs;

    while (my $stage = shift @stages) {
        $stage = $self->{+STAGED}->stage_lookup->{$stage} unless ref $stage || $stage eq 'NOPRELOAD';

        my $proc = $self->launch_stage($stage);

        if ($proc) {
            push @procs => $proc;
            next;
        }

        # We are in the stage now, reset these
        if (ref $stage) {
            $name   = $stage->name;
            @procs  = ();
            @stages = @{$stage->children};
        }
        else { # NOPRELOAD
            $name   = $stage;
            @procs  = ();
            @stages = ();
        }

        $self->start_stage($stage);
    }

    return($name, @procs);
}

sub launch_stage {
    my $self = shift;
    my ($stage) = @_;

    $stage = $self->{+STAGED}->stage_lookup->{$stage} unless ref $stage || $stage eq 'NOPRELOAD';

    my $name = ref($stage) ? $stage->name : $stage;

    my $pid = fork();

    return Test2::Harness::Runner::Preloader::Stage->new(
        pid => $pid,
        name => $name,
    ) if $pid;

    $0 .= "-$name";
    $ENV{T2_HARNESS_STAGE} = $name;

    return;
}

sub start_stage {
    my $self = shift;
    my ($stage) = @_;

    if ($self->{+STAGED}) {
        if ($stage && !ref($stage)) {
            $stage = $self->{+STAGED}->stage_lookup->{$stage};
        }
    }
    else {
        $stage = undef;
    }

    $self->load_blacklist if $self->{+MONITOR};

    # Localize these in case something we preload tries to modify them.
    local $SIG{INT}  = $SIG{INT};
    local $SIG{HUP}  = $SIG{HUP};
    local $SIG{TERM} = $SIG{TERM};

    my $preloads = $stage ? $stage->load_sequence : [];

    my $meth = $self->{+MONITOR} ? '_monitor_preload' : '_preload';

    $self->$meth($preloads) if $preloads && @$preloads;

    $self->_monitor() if $self->{+MONITOR};
}

sub check {
    my $self = shift;

    return 1 if $self->{+CHANGED};

    return 0 unless $self->{+MONITOR};

    my $changed = USE_INOTIFY ? $self->_check_monitored_inotify : $self->_check_monitored_hardway;
    return 0 unless $changed;

    $self->{+CHANGED} = 1;
    print "$$ $0 - Runner detected a change in one or more preloaded modules, blacklisting changed files and reloading...\n";

    my %CNI = reverse %INC;
    my @todo = map {[file2mod($CNI{$_}), $_]} keys %$changed;

    my $bl = $self->_lock_blacklist();

    my $dep_map = $self->dtrace->dep_map;

    my %seen;
    while (@todo) {
        my $set = shift @todo;
        my ($pkg, $full) = @$set;
        my $file = $CNI{$full} || $full;
        next if $seen{$file}++;
        next if $pkg->can('TEST2_HARNESS_PRELOAD');
        print $bl "$pkg\n";
        my $next = $dep_map->{$file} or next;
        push @todo => @$next;
    }

    $self->_unlock_blacklist();

    return 1;
}

sub _monitor_preload {
    my $self = shift;
    my ($preloads) = @_;

    my $block  = {%{$self->blacklist}};
    my $dtrace = $self->dtrace;

    $dtrace->start;
    $self->_preload($preloads, $block, $dtrace->my_require);
    $dtrace->stop;

    return;
}

sub _preload {
    my $self = shift;
    my ($preloads, $block, $require_sub) = @_;

    $block //= {};

    my %seen;
    for my $mod (@$preloads) {
        next if $seen{$mod}++;

        if (ref($mod) eq 'CODE') {
            next if eval { $mod->($block, $require_sub); 1 };
            $self->{+MONITOR} ? warn $@ : die $@;
            next;
        }

        next if $block && $block->{$mod};

        next if eval { $self->_preload_module($mod, $block, $require_sub); 1 };
        $self->{+MONITOR} ? warn $@ : die $@;
    }

    return;
}

sub _preload_module {
    my $self = shift;
    my ($mod, $block, $require_sub) = @_;

    my $file = mod2file($mod);

    $require_sub ? $require_sub->($file) : require $file;

    return unless $mod->can('TEST2_HARNESS_PRELOAD');

    die "You cannot load a Test2::Harness::Runner::Preload module from within another" if $self->{+DONE};

    $self->{+STAGED} //= do {
        require Test2::Harness::Runner::Preload;
        Test2::Harness::Runner::Preload->new();
    };

    $self->{+STAGED}->merge($mod->TEST2_HARNESS_PRELOAD);

    return;
}

sub eager_stages {
    my $self = shift;

    return unless $self->{+STAGED};
    return $self->{+STAGED}->eager_stages;
}

sub load_blacklist {
    my $self = shift;

    my $bfile     = $self->{+BLACKLIST_FILE};
    my $blacklist = $self->{+BLACKLIST};

    return unless -f $bfile;

    my $fh = open_file($bfile, '<');
    while(my $pkg = <$fh>) {
        chomp($pkg);
        $blacklist->{$pkg} = 1;
    }
}

sub _monitor {
    my $self = shift;

    if ($self->{+MONITORED} && $self->{+MONITORED}->[0] == $$) {
        die "Monitor already starated\n" . "\n=======\n$0\n" . Carp::longmess() . "\n=====\n" . $self->{+MONITORED}->[1] . "\n" . $self->{+MONITORED}->[2] . "\n=======\n";
    }

    delete $self->{+INOTIFY};
    $self->{+MONITORED} = [$$, $0, Carp::longmess()];

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

sub _lock_blacklist {
    my $self = shift;

    return $self->{+BLACKLIST_LOCK} if $self->{+BLACKLIST_LOCK};

    my $bl = lock_file($self->{+BLACKLIST_FILE}, '>>');
    seek($bl,2,0);

    return $self->{+BLACKLIST_LOCK} = $bl;
}

sub _unlock_blacklist {
    my $self = shift;

    my $bl = delete $self->{+BLACKLIST_LOCK} or return;

    $bl->flush;
    unlock_file($bl);
    close($bl);

    return;
}

1;


__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preloader - Preload logic.

=head1 DESCRIPTION

This module is responsible for preloading libraries before running tests. This
entire module is considered an "Implementation Detail". Please do not rely on
it always staying the same, or even existing in the future. Do not use this
directly.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

