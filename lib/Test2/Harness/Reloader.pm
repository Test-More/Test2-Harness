package Test2::Harness::Reloader;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken/;

use Test2::Harness::Util qw/clean_path file2mod/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json/;

our $VERSION = '2.000000';

BEGIN {
    local $@;
    my $inotify = eval { require Linux::Inotify2; 1 };
    if ($inotify) {
        *USE_INOTIFY = sub() { 1 };
    }
    else {
        *USE_INOTIFY = sub() { 0 };
    }
}

use Test2::Harness::Util::HashBase qw{
    <restrict
    <stage
    <stage_name
    +file_info
};

my $ACTIVE;
sub ACTIVE { $ACTIVE }

{
    no warnings 'redefine';
    my $oldnew = \&new;
    *new = sub {
        my $class = shift;

        if ($class eq __PACKAGE__) {
            if (USE_INOTIFY) {
                require Test2::Harness::Reloader::Inotify2;
                $class = 'Test2::Harness::Reloader::Inotify2';
            }
            else {
                require Test2::Harness::Reloader::Stat;
                $class = 'Test2::Harness::Reloader::Stat';
            }
        }

        unshift @_ => $class;

        goto &$oldnew;
    };
}

sub init {
    my $self = shift;

    $self->{+RESTRICT} //= [];

    my $stage = delete $self->{+STAGE};
    if (ref $stage) {
        $self->{+STAGE} = $stage;
        $self->{+STAGE_NAME} = $stage->name;
    }
    else {
        $self->{+STAGE_NAME} = $stage;
    }

    $self->{+STAGE_NAME} //= $ENV{T2_HARNESS_STAGE} // "Unknown stage";
}

sub start             { croak "$_[0] does not implement 'start'" }
sub stop              { croak "$_[0] does not implement 'stop'" }
sub watch             { croak "$_[0] does not implement 'watch'" }
sub changed_files     { croak "$_[0] does not implement 'changed_files'" }

sub file_has_callback { undef }

sub find_files_to_watch {
    my $self = shift;

    my %watches;
    if (my $stage = $self->stage) {
        %watches = %{$stage->watches};
    }

    for my $file (map { clean_path($_) } values %INC) {
        next unless $self->should_watch($file);
        $watches{$file} //= 1;
    }

    return \%watches;
}

sub set_active {
    my $self = shift;

    return if $ACTIVE && $ACTIVE == $self;

    croak "There is already an active reloader" if $ACTIVE;

    $ACTIVE = $self;
    weaken($ACTIVE);
}

sub should_watch {
    my $self = shift;
    my ($file) = @_;

    my $restrict = $self->{+RESTRICT} or return 1;
    return 1 unless @$restrict;

    for my $dir (@$restrict) {
        return 1 if 0 == index($file, $dir);
    }

    return 0;
}

sub check_reload {
    my $self = shift;

    my $changed = $self->changed_files or return 0;
    return 0 unless @$changed;

    my @to_reload;

    for my $file (@$changed) {
        # Force a restart
        my ($status, %fields) = $self->can_reload_file($file);
        unless ($status) {
            $fields{reason} //= "No reason given";
            print STDERR "Cannot reload file '$file' in place: $fields{reason}\n  Restarting Stage '$self->{+STAGE_NAME}'...\n";
            return 1;
        }

        push @to_reload => $file;
    }

    for my $file (@to_reload) {
        my ($status, %fields);
        unless(eval { ($status, %fields) = $self->reload_file($file); 1 }) {
            %fields = (reason => $@);
            $status = 0;
        }

        unless ($status) {
            $fields{reason} //= "No reason given";
            print STDERR "Cannot reload file '$file' in place: $fields{reason}\n  Restarting Stage '$self->{+STAGE_NAME}'...\n";
            return 1;
        }
    }

    return 0;
}

sub file_info {
    my $self = shift;
    my ($file) = @_;

    $file = clean_path($file);

    return $self->{+FILE_INFO}->{$file} if $self->{+FILE_INFO}->{$file};

    my $info = {file => $file};

    warn "TODO: Check for churn";
    warn "TODO: Check for stage in-place check";

    $info->{callback} = $self->file_has_callback($file);

    if ($file =~ m/\.(pl|pm|t)$/i) {
        $info->{perl} = 1;

        my %lookup;
        for my $short (keys %INC) {
            my $long = $INC{$short};
            $lookup{clean_path($long)} = $short;
        }

        if (my $modfile = $lookup{$file}) {
            my $mod = file2mod($modfile);
            $info->{module}    = $mod;
            $info->{inc_entry} = $modfile;

            $info->{has_import} = $mod->can('import');
            $info->{t2_preload} = $mod->can('TEST2_HARNESS_PRELOAD');
        }
    }
    else {
        $info->{perl} = 0;
    }

    return $self->{+FILE_INFO}->{$file} = $info;
}

sub can_reload_file {
    my $self = shift;
    my ($file) = @_;

    my $info = $self->file_info($file);

    return (1) if $info->{callback};

    return (0, reason => "$file is not a perl module, and no callback was provided for reloading it") unless $info->{perl};

    my $mod = $info->{module} or return (0, reason => "Unable to find the package associated with file '$file'");

    return (0, reason => "Module $mod is a yath preload module") if $info->{t2_preload};
    return (0, reason => "Module $mod has an import() method")   if $info->{has_import};

    return (1);
}

sub reload_file {
    my $self = shift;
    my ($file) = @_;

    warn "TODO: check plugin/preload callbacks";

    if (my $cb = $self->file_has_callback($file)) {
        my ($status, %fields) = $cb->($file);
        return ($status, %fields) if defined $status;
    }

    return $self->do_reload($file);
}

sub do_reload {
    my $self = shift;
    my ($file) = @_;

    my $info = $self->file_info($file);
    my $mod = $info->{module};

    my @warnings;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @warnings => @_ };

        if ($mod) {
            my $stash = do { no strict 'refs'; \%{"${mod}\::"} };
            for my $sym (keys %$stash) {
                next if $sym =~ m/::$/;

                delete $stash->{$sym};
            }
        }

        delete $INC{$info->{inc_entry}};
        local $.;
        require $file;

        1;
    };
    my $err = $@;

    return (0, reason => $err) unless $ok;
    return (0, reason => "Got warnings: " . encode_pretty_json(\@warnings)) if @warnings;
    return (1);
}

1;

__END__



__END__

use Test2::Harness::Util::HashBase qw{
    <notify_cb <find_loaded_cb <should_watch_cb <can_reload_cb <reload_cb <delete_symbol_cb
    <monitored <monitor_lookup
    <watcher
    <stat_min_gap <stat_last_checked
    <pid
};

sub _pid_check {
    my $self = shift;

    return 1 unless USE_INOTIFY;

    my $pid = $self->{+PID} //= $$;

    croak "PID has changed $$ vs $pid (Maybe you need to call reset()?)"
        unless $$ == $pid;

    return 1;
}

sub init {
    my $self = shift;
    $self->{+CAN_RELOAD_CB}  //= $self->can('_can_reload');
    $self->{+FIND_LOADED_CB} //= $self->can('_find_loaded');
    $self->{+STAT_MIN_GAP}   //= 2;

    $self->reset;
}

sub reset {
    my $self = shift;
    delete $self->{+PID};
    $self->{+MONITORED} = {};
    $self->{+MONITOR_LOOKUP} = {};
    if (USE_INOTIFY) {
        $self->{+WATCHER} = Linux::Inotify2->new;
        $self->{+WATCHER}->blocking(0);
    } else {
        $self->{+WATCHER} = {};
    }
    delete $self->{+STAT_LAST_CHECKED};
}

sub _find_loaded { keys %INC }

sub refresh {
    my $self = shift;

    $self->_pid_check();

    my $monitored = $self->{+MONITORED};

    my $cb = $self->{+FIND_LOADED_CB};
    for my $file ($self->$cb($monitored)) {
        next if exists $monitored->{$file};
        $self->monitor($file);
    }
}

sub monitor {
    my $self = shift;
    my ($file) = @_;

    $self->_pid_check();

    my $monitored = $self->{+MONITORED};
    return if exists $monitored->{$file};

    my $watch = $self->find_file_to_watch($file);

    return $monitored->{$file} = 0 unless $watch && -e $watch;

    if (my $should_watch_cb = $self->{+SHOULD_WATCH_CB}) {
        return $monitored->{$file} = 0 unless $self->$should_watch_cb($file => $watch);
    }

    if (USE_INOTIFY) {
        my $inotify = $self->{+WATCHER};
        $inotify->watch($watch, INOTIFY_MASK());
    }
    else {
        my $stats = $self->{+WATCHER};
        $stats->{$watch} = $self->_get_file_times($watch);
    }

    $self->{+MONITOR_LOOKUP}->{$watch} = $file;
    $monitored->{$file} = $watch;
    return $watch;
}

sub find_file_to_watch {
    my $self = shift;
    my ($file) = @_;

    return $INC{$file} if $INC{$file} && -e $INC{$file};

    for my $dir (@INC) {
        next if ref($dir);
        my $path = File::Spec->catfile($dir, $file);
        return $path if -f $path;
    }

    return $file if -e $file;
}

sub _get_file_times {
    my $self = shift;
    my ($file) = @_;
    my (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime, $ctime) = stat($file);
    return [$mtime, $ctime];
}

sub _get_changes {
    my $self = shift;

    if (USE_INOTIFY) {
        my $inotify = $self->{+WATCHER};
        my @todo = $inotify->read or return;
        return {map { ($_->fullname() => 1) } @todo};
    }

    # Do not hammer the disk getting stat
    my $check_time = time;
    my $gap = $self->{+STAT_MIN_GAP};
    my $last_checked = $self->{+STAT_LAST_CHECKED};
    return if $last_checked && $gap && $gap > ($check_time - $last_checked);
    $last_checked = $check_time;

    my $found = 0;
    my $changed = {};
    my $stats = $self->{+WATCHER};
    for my $file (keys %$stats) {
        my $old_times = $stats->{$file};
        my $new_times = $self->_get_file_times($file);

        # Compare times
        next if $old_times->[0] == $new_times->[0] && $old_times->[1] == $new_times->[1];

        # Update in case we choose not to reload
        $stats->{$file} = $new_times;

        $found++;
        $changed->{$file} = 1;
    }

    return unless $found;
    return $changed;
}

sub _can_reload {
    my %params = @_;

    my $mod = $params{module};

    return 1 unless $mod->can('import');

    return 0 if $mod->can('IMPORTER_MENU');

    {
        no strict 'refs';
        return 0 if @{"$mod\::EXPORT"};
        return 0 if @{"$mod\::EXPORT_OK"};
    }

    return 1;
}

sub reload_changes {
    my $self = shift;

    $self->_pid_check();

    my $monitored = $self->{+MONITORED};

    $self->refresh();

    my $changed = $self->_get_changes() or return;

    my $notify_cb = $self->{+NOTIFY_CB};

    $notify_cb->(changes_detected => [keys %$changed]) if $notify_cb;

    my %out;
    for my $file (sort keys %$changed) {
        if (USE_INOTIFY) {
            my $inotify = $self->{+WATCHER};
            $inotify->watch($file, INOTIFY_MASK());
        }

        $notify_cb->(file_changed => $file) if $notify_cb;

        my $rel    = $self->{+MONITOR_LOOKUP}->{$file};
        my $mod    = file2mod($rel);
        my %params = (reloader => $self, file => $file, relative => $rel, module => $mod, notify_cb => $notify_cb);

        my ($status, %fields) = $self->_reload_file(%params);

        $out{$file} = {
            file     => $file,
            relative => $rel,
            module   => $mod,
            reloaded => $status,
            %fields,
        };
    }

    return \%out;
}

sub _reload_file {
    my $self   = shift;
    my %params = @_;

    if (my $reload_cb = $self->{+RELOAD_CB}) {
        my ($status, %fields) = $reload_cb->(%params);
        return ($status, %fields) if defined $status;
    }

    if (my $can_reload_cb = $self->{+CAN_RELOAD_CB}) {
        my ($can, %fields) = $can_reload_cb->(%params);
        return ($can, %fields) unless $can;
    }

    my $notify_cb = delete $params{notify_cb};
    $notify_cb->(reload_inplace => \%params) if $notify_cb;

    my $del_cb = $self->{+DELETE_SYMBOL_CB};
    my ($file, $rel, $mod) = @params{qw/file relative module/};

    my @warnings;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @warnings => @_ };

        my $stash = do { no strict 'refs'; \%{"${mod}\::"} };
        for my $sym (keys %$stash) {
            next if $sym =~ m/::$/;

            next if $del_cb && $del_cb->(%params, symbol => $sym, stash => $stash);

            delete $stash->{$sym};
        }

        delete $INC{$rel};
        local $.;
        require $rel;
        die "Reloading '$rel' loaded '$INC{$rel}' instead of '$file', \@INC must have been altered"
            unless is_same_file($file, $INC{$rel});

        1;
    };
    my $err = $@;

    return (1) if $ok && !@warnings;

    $notify_cb->(reload_fail => {%params, warnings => \@warnings, error => $err}) if $notify_cb;

    return (undef, error => $err, warnings => \@warnings);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Reloader - reload logic.

=head1 DESCRIPTION

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

