package Test2::Harness::Runner::Preloader;
use strict;
use warnings;

our $VERSION = '1.000155';

use B();
use Carp qw/confess croak/;
use Fcntl qw/LOCK_EX LOCK_UN/;
use Time::HiRes qw/time sleep/;
use Test2::Harness::Util qw/open_file file2mod mod2file lock_file unlock_file clean_path/;

use Test2::Harness::Runner::Reloader;
use Test2::Harness::Runner::Preloader::Stage;

use File::Spec();
use List::Util qw/pairgrep/;

use Test2::Harness::Util::HashBase(
    qw{
        <dir
        <preloads
        <done
        <below_threshold

        <dtrace <reloader

        <staged <started_stages <stage

        <dump_depmap
        <changed
        <restrict_reload

        <blacklist_file
        <blacklist_lock
        <blacklist

        <monitored
    },

    '<monitor', # This means watch for changes, restart stage if any found
    '<reload',  # Try to reload in place instead of restart stage
);

sub init {
    my $self = shift;

    $self->{+PRELOADS} //= [];

    $self->{+BELOW_THRESHOLD} //= 0;

    return if $self->{+BELOW_THRESHOLD};

    $self->{+MONITOR} = 1 if $self->{+RELOAD};

    my $need_depmap = $self->{+RELOAD} || $self->{+MONITOR} || $self->{+DUMP_DEPMAP};

    if ($need_depmap) {
        require Test2::Harness::Runner::DepTracer;
        $self->{+DTRACE} //= Test2::Harness::Runner::DepTracer->new();
    }

    if ($self->{+MONITOR} || $self->{+RELOAD}) {
        $self->{+BLACKLIST}      //= {};
        $self->{+BLACKLIST_FILE} //= File::Spec->catfile($self->{+DIR}, 'BLACKLIST');
    }

    $self->{+RELOADER} = Test2::Harness::Runner::Reloader->new(
        stat_min_gap     => 2,
        notify_cb        => sub { $self->_reload_cb_notify(@_) },
        find_loaded_cb   => sub { $self->_reload_cb_find_loaded(@_) },
        should_watch_cb  => sub { $self->_reload_cb_should_watch(@_) },
        can_reload_cb    => sub { $self->_reload_cb_can_reload(@_) },
        reload_cb        => sub { $self->_reload_cb_reload(@_) },
        delete_symbol_cb => sub { $self->_reload_cb_delete_symbol(@_) },
    );
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

    $wants //= "";

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
    if ($self->{+MONITOR} || $self->{+DTRACE}) {
        $self->_monitor_preload($preloads);
    }
    else {
        $self->_preload($preloads);
    }

    $self->{+DONE} = 1;
}

sub preload_stages {
    my $self = shift;
    return 'default' unless $self->{+STAGED};
    return $self->_preload_stages('NOPRELOAD', @{$self->{+STAGED}->stage_list});
}

sub _preload_stages {
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

    $self->{+STAGE} = $stage;

    $self->load_blacklist if $self->{+MONITOR};

    # Localize these in case something we preload tries to modify them.
    local $SIG{INT}  = $SIG{INT};
    local $SIG{HUP}  = $SIG{HUP};
    local $SIG{TERM} = $SIG{TERM};

    my $preloads = $stage ? $stage->load_sequence : [];

    my $meth = $self->{+MONITOR} || $self->{+DTRACE} ? '_monitor_preload' : '_preload';

    $self->$meth($preloads, $stage->watches) if $preloads && @$preloads;

    $self->_monitor() if $self->{+MONITOR};
}

sub get_stage_callback {
    my $self   = shift;
    my ($name) = @_;

    my $stage = $self->{+STAGE} or return undef;
    return undef unless ref $stage;
    return $stage->$name;
}

sub _monitor_preload {
    my $self = shift;
    my ($preloads, $watch) = @_;

    my $block  = {%{$self->blacklist}};
    my $dtrace = $self->dtrace;

    $dtrace->start;
    $self->_preload($preloads, $block, $dtrace->my_require);
    $dtrace->add_callbacks(%$watch) if $watch;
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

sub _notify {
    my $self = shift;
    for my $msg (@_) {
        print "$$ $0 - $msg\n";
    }
}

sub _reload_cb_notify {
    my $self = shift;
    my ($type, $info) = @_;

    return $self->_notify("Runner detected a change in one or more preloaded modules...")
        if $type eq 'changes_detected';

    return $self->_notify("Runner detected changes in file '$info'...")
        if $type eq 'file_changed';

    return $self->_notify("Runner attempting to reload '$info->{file}' in place...")
        if $type eq 'reload_inplace';

    return $self->_notify(
        "Runner failed to reload '$info->{file}' in place...",
        map { split /\n/, $_ } grep { $_ } @{$info->{warnings} // []}, $info->{error},
    ) if $type eq 'reload_fail';

    require Data::Dumper;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Maxdepth = 2;
    return $self->_notify("Runner notification $type: " . (ref($info) ? Data::Dumper::Dumper($info) : $info) . "...");
}

sub _reload_cb_find_loaded { keys %{$_[0]->dtrace->loaded} }

sub _reload_cb_should_watch {
    my $self = shift;
    my ($reloader, $rel, $abs) = @_;

    my $dirs = $self->{+RESTRICT_RELOAD};
    return 1 unless $dirs && @$dirs;

    for my $dir (@$dirs) {
        return 1 if 0 == index($abs, $dir);
    }

    return 0;
}

sub _reload_cb_can_reload {
    my $self = shift;
    my %params = @_;

    my $mod  = $params{module};
    my $file = $params{file};

    return (0, reason => 'File is a yath preload module') if $mod->can('TEST2_HARNESS_PRELOAD');

    if (my $cb = $self->get_stage_callback('reload_inplace_check')) {
        my ($res, %fields) = $cb->(module => $mod, file => $file);
        return ($res, %fields) if defined $res;
    }

    return (1) unless $mod->can('import');

    return (0, reason => 'File is an importer') if $mod->can('IMPORTER_MENU');

    {
        no strict 'refs';
        return (0, reason => 'File is an importer') if @{"$mod\::EXPORT"};
        return (0, reason => 'File is an importer') if @{"$mod\::EXPORT_OK"};
    }

    return (1);
}

sub find_churn {
    my $self = shift;
    my ($file) = @_;

    # When a file is saved to disk it seems it can vanish temporarily. Use this loop to wait for it...
    my ($fh, $ok, $error);
    for (1 .. 50) {
        local $@;
        $ok = eval { $fh = open_file($file) };
        $error = "LOOP $_: $@";
        last if $ok;
        sleep 0.2;
    }

    die $error // "Unknown error opening file '$file'" unless $fh;

    my $active = 0;
    my @out;

    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;

        if ($active) {
            if ($line =~ m/^\s*#\s*HARNESS-CHURN-STOP\s*$/) {
                push @{$out[-1]} => $line_no;
                $active = 0;
                next;
            }
            else {
                $out[-1][-1] .= $line;
                next;
            }
        }

        if ($line =~ m/^\s*#\s*HARNESS-CHURN-START\s*$/) {
            $active = 1;
            push @out => [$line_no, ''];
        }
    }

    return @out;
}

sub _reload_cb_reload {
    my $self = shift;
    my %params = @_;

    my ($file, $rel, $mod) = @params{qw/file relative module/};

    my $callbacks;
    if (my $dtrace = $self->dtrace) {
        $callbacks = $dtrace->callbacks;
    }
    $callbacks //= {};

    if (my $cb = $callbacks->{$file} // $callbacks->{$rel}) {
        $self->_notify("Changed file '$rel' has a reload callback, executing it instead of regular reloading...");
        my $ret = $cb->();
        return (1, callback_return => $ret);
    }

    if (my @churn = $self->find_churn($file)) {
        $self->_notify("Changed file '$rel' contains churn sections, running them instead of a full reload...");

        for my $churn (@churn) {
            my ($start, $code, $end) = @$churn;
            my $sline = $start + 1;
            if (eval "package $mod;\nuse strict;\nuse warnings;\nno warnings 'redefine';\n#line $sline $file\n$code\n ;1;") {
                $self->_notify("Success reloading churn block ($file lines $start -> $end)");
            }
            else {
                $self->_notify("Error reloading churn block ($file lines $start -> $end): $@");
            }
        }

        return (1);
    }

    return (0, reason => 'reloading disabled') unless $self->{+RELOAD};

    return undef;
}

sub _reload_cb_delete_symbol {
    my $self = shift;
    my %params = @_;

    my $sym = $params{symbol};
    my $mod = $params{module};
    my $file = $params{file};

    # Make sure the changed file and the file that defined the sub are the same.
    my $cb      = $self->get_stage_callback('reload_remove_check') or return 0;
    my $sub     = $mod->can($sym)                                  or return 0;
    my $cobj    = B::svref_2object($sub)                           or return 0;
    my $subfile = $cobj->FILE                                      or return 0;

    my $res = $cb->(
        mod         => $mod,
        sym         => $sym,
        sub         => $sub,
        from_file   => -f $subfile ? clean_path($subfile) : $subfile,
        reload_file => -f $file    ? clean_path($file)    : $file,
    );

    # 0 means do not skip, so if the cb returned true we do not skip
    return 0 if $res;
    return 1;
}

sub _monitor {
    my $self = shift;

    if ($self->{+MONITORED} && $self->{+MONITORED}->[0] == $$) {
        die "Monitor already starated\n" . "\n=======\n$0\n" . Carp::longmess() . "\n=====\n" . $self->{+MONITORED}->[1] . "\n" . $self->{+MONITORED}->[2] . "\n=======\n";
    }

    $self->{+MONITORED} = [$$, $0, Carp::longmess()];

    my $reloader = $self->{+RELOADER};
    $reloader->reset();
    $reloader->refresh();

    return $self->{+MONITORED};
}

sub check {
    my $self = shift;
    my ($state) = @_;

    return 1 if $self->{+CHANGED};

    return 0 unless $self->{+MONITOR};

    my $dtrace = $self->dtrace;
    $dtrace->start if $self->{+RELOAD};

    my $results = $self->{+RELOADER}->reload_changes();

    $dtrace->stop if $self->{+RELOAD};

    my (@todo, @fails);
    for my $item (values %$results) {
        my $stage = $self->{+STAGE} ? $self->{+STAGE}->name : 'default';
        $state->reload($stage => $item);
        my $rel = $item->{reloaded};

        next if $rel; # Reload success

        if (defined $rel) { # Not reloaded, but no error
            push @todo => $item;
            next;
        }
    }

    unless (@todo) {
        $self->{+RELOADER}->refresh();
        return 0;
    }

    $self->{+CHANGED} = 1;
    $self->_notify("blacklisting changed files and reloading stage...");

    my $bl = $self->_lock_blacklist();

    my $dep_map = $self->dtrace->dep_map;

    my %CNI = reverse pairgrep { $b } %INC;

    my %seen;
    while (@todo) {
        my $item = shift @todo;
        my $ref = ref($item);

        my ($mod, $abs, $rel);
        if ($ref eq 'HASH') {
            ($mod, $abs, $rel) = @{$item}{qw/module file relative/};
        }
        elsif ($ref eq 'ARRAY') {
            ($mod, $abs) = @$item;
            $rel = $CNI{$abs} || $abs;
        }
        else {
            die "Invalid ref type: $ref";
        }

        next if $seen{$abs}++;
        next if $mod->can('TEST2_HARNESS_PRELOAD');
        $self->_notify("Blacklisting $mod...");
        print $bl "$mod\n";
        my $next = $dep_map->{$abs} or next;
        push @todo => @$next;
    }

    $self->_unlock_blacklist();

    return 1;
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

