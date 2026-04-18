package Test2::Harness2::Reloader;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/weaken/;
use B();

use Test2::Harness2::Util qw/clean_path file2mod/;

BEGIN {
    my $inotify = eval { require Linux::Inotify2; 1 };
    if ($inotify) {
        *USE_INOTIFY = sub() { 1 };
    }
    else {
        *USE_INOTIFY = sub() { 0 };
    }
}

use Object::HashBase qw{
    <restrict
    <stage
    <stage_name
    +file_info
    <in_place

    <watches
    <watched
};

my $ACTIVE;

sub ACTIVE {
    return unless $ACTIVE;
    return $ACTIVE->[1] if $ACTIVE->[1] && $ACTIVE->[0] == $$;
    $ACTIVE = undef;
    return;
}

{
    no warnings 'redefine';
    my $oldnew = \&new;
    *new = sub {
        my $class = shift;

        if ($class eq __PACKAGE__) {
            if (USE_INOTIFY) {
                require Test2::Harness2::Reloader::Inotify2;
                $class = 'Test2::Harness2::Reloader::Inotify2';
            }
            else {
                require Test2::Harness2::Reloader::Stat;
                $class = 'Test2::Harness2::Reloader::Stat';
            }
        }

        unshift @_ => $class;
        goto &$oldnew;
    };
}

sub changed_files { croak "$_[0] does not implement 'changed_files'" }
sub do_watch      { croak "$_[0] does not implement 'do_watch'" }

sub init {
    my $self = shift;

    $self->{+RESTRICT} //= [];
    $self->{+WATCHES}  //= {};
    $self->{+WATCHED}  //= {};

    my $stage = delete $self->{+STAGE};
    if (ref $stage) {
        $self->{+STAGE}      = $stage;
        $self->{+STAGE_NAME} = $stage->name;
    }
    else {
        $self->{+STAGE_NAME} = $stage;
    }

    $self->{+STAGE_NAME} //= $ENV{T2_HARNESS_STAGE} // "Unknown stage";
}

sub start {
    my $self = shift;

    my $watches = $self->find_files_to_watch;
    my $watched = $self->{+WATCHED} //= {};

    # Files the user pre-registered via watch() before the backend was ready
    # need to be folded into the set start() registers. find_files_to_watch
    # covers %INC and the stage's declared watches; anything else the caller
    # explicitly asked us to watch lives in $self->{+WATCHES}.
    my $watches_map = $self->{+WATCHES} //= {};
    for my $file (keys %$watches_map) {
        $watches->{$file} //= $watches_map->{$file};
    }

    for my $file (keys %$watches) {
        # Re-run do_watch when a prior pre-start call left an undef marker
        # behind because the backend had not yet been initialized.
        my $cur = $watched->{$file};
        next if defined $cur;
        $watched->{$file} = $self->do_watch($file, $watches->{$file});
    }
}

sub stop {
    my $self = shift;
    $self->{+WATCHED} = {};
    return;
}

sub watch {
    my $self = shift;
    my ($file, $cb) = @_;

    my $watches = $self->{+WATCHES} //= {};
    my $watched = $self->{+WATCHED} //= {};

    croak "The first argument must be a file (got: $file)"
        unless $file && -f $file;

    $file = clean_path($file);

    my $val = $cb // $watches->{$file} // 1;

    $watched->{$file} //= $self->do_watch($file, $val);
    $watches->{$file} = $val;

    return $val;
}

sub file_has_callback {
    my $self = shift;
    my ($file) = @_;

    my $watched = $self->{+WATCHED} //= {};

    my $cb  = $watched->{$file} or return undef;
    my $ref = ref($cb)          or return undef;
    return $cb if $ref eq 'CODE';
    return undef;
}

sub find_files_to_watch {
    my $self = shift;

    my %watches;
    if (my $stage = $self->stage) {
        %watches = %{$stage->watches};
    }

    for my $file (map { $_ ? clean_path($_) : () } values %INC) {
        next if ref $file;
        next unless -e $file;
        next unless $self->should_watch($file);
        $watches{$file} //= 1;
    }

    return \%watches;
}

sub set_active {
    my $self = shift;

    croak "There is already an active reloader" if $self->ACTIVE;

    $ACTIVE = [$$, $self];
    weaken($ACTIVE->[1]);
}

sub should_watch {
    my $self = shift;
    my ($file) = @_;

    return 0 unless $file;

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
    return unless @$changed;

    my @to_reload;
    my @cannot_reload;
    my $bad = 0;

    for my $file (sort @$changed) {
        my $info = $self->file_info($file);

        my ($status, %fields) = $self->can_reload_file($file, $info);
        if (!$status) {
            $fields{reason} //= "No reason given";
            warn "$$ $0 - Cannot reload file '$file' in place: $fields{reason}\n"
                . "  Restarting Stage '$self->{+STAGE_NAME}'...\n";
            push @cannot_reload => $info->{module} if $info->{module};
            $bad++;
        }
        elsif ($status < 0) {
            push @cannot_reload => $info->{module} if $info->{module};
            $bad++;
        }
        else {
            push @to_reload => [$file, $info];
        }
    }

    for my $set (@to_reload) {
        my ($file, $info) = @$set;
        my ($status, %fields);
        my $ok = eval { ($status, %fields) = $self->reload_file($file, $info); 1 };
        my $err = $@;
        unless ($ok) {
            %fields = (reason => $err);
            $status = 0;
        }

        unless ($status) {
            $fields{reason} //= "No reason given";
            warn "$$ $0 - Cannot reload file '$file' in place: $fields{reason}\n"
                . "  Restarting Stage '$self->{+STAGE_NAME}'...\n";
            push @cannot_reload => $info->{module} if $info->{module};
            $bad++;
        }
    }

    return unless $bad || @cannot_reload;
    return \@cannot_reload;
}

sub file_info {
    my $self = shift;
    my ($file) = @_;

    $file = clean_path($file);

    return $self->{+FILE_INFO}->{$file} if $self->{+FILE_INFO}->{$file};

    my $info = {file => $file};

    if (my $stage = $self->stage) {
        $info->{reload_inplace_check} = $stage->reload_inplace_check;
    }
    $info->{callback} = $self->file_has_callback($file);

    if ($file =~ m/\.(pl|pm|t)$/i) {
        $info->{perl} = 1;

        my %lookup;
        for my $short (keys %INC) {
            my $long = $INC{$short};
            next unless defined $long && !ref $long;
            $lookup{clean_path($long)} = $short;
        }

        if (my $modfile = $lookup{$file}) {
            my $mod = file2mod($modfile);
            $info->{module}    = $mod;
            $info->{inc_entry} = $modfile;

            if (my $imp = $mod->can('import')) {
                my $cobj     = B::svref_2object($imp);
                my $impfile  = $cobj->FILE    // 'NONE';
                my $package  = $cobj->GV->STASH->NAME // 'NONE';

                # Perl 5.40 adds a UNIVERSAL::import we should ignore
                $info->{has_import} = 1 unless $package eq 'UNIVERSAL' || $impfile eq 'universal.c';
            }

            $info->{t2_preload} = $mod->can('TEST2_HARNESS_PRELOAD');
            $info->{is_moose}   = _looks_like_moose($mod);
        }

        if (my @churn = $self->find_churn($file)) {
            $info->{churn} = \@churn;
        }
    }
    else {
        $info->{perl} = 0;
    }

    return $self->{+FILE_INFO}->{$file} = $info;
}

sub _looks_like_moose {
    my ($mod) = @_;
    return 0 unless $mod;
    return 0 unless $mod->can('meta');
    my $meta = eval { $mod->meta };
    return 0 unless $meta;
    return 1 if $meta->isa('Moose::Meta::Class');
    return 1 if $meta->isa('Moose::Meta::Role');
    return 0;
}

sub can_reload_file {
    my $self = shift;
    my ($file, $info) = @_;

    $info //= $self->file_info($file);

    return (1) if $info->{churn};
    return (1) if $info->{callback};

    return (-1, reason => "In-place reloading is disabled (enable with --reload)")
        unless $self->{+IN_PLACE};

    if (my $cb = $info->{reload_inplace_check}) {
        my ($res, %fields) = $cb->(%$info);
        return ($res, %fields) if defined $res;
    }

    return (0, reason => "$file is not a perl module, and no callback was provided for reloading it")
        unless $info->{perl};

    my $mod = $info->{module}
        or return (0, reason => "Unable to find the package associated with file '$file'");

    return (0, reason => "Module $mod is a yath preload module") if $info->{t2_preload};

    # Moose and exporter modules are handled by dedicated reload helpers when
    # those helpers are available; fall through to those rather than bailing
    # out of in-place reload.
    return (1) if $info->{is_moose} && _moose_reloader_available();
    return (1) if $info->{has_import} && _exporter_reloader_available();

    return (0, reason => "Module $mod has an import() method") if $info->{has_import};

    return (1);
}

sub _moose_reloader_available {
    return 0 unless eval { require Test2::Harness2::Reloader::Moose; 1 };
    return Test2::Harness2::Reloader::Moose->viable;
}

sub _exporter_reloader_available {
    return 0 unless eval { require Test2::Harness2::Reloader::Exporter; 1 };
    return Test2::Harness2::Reloader::Exporter->viable;
}

sub reload_file {
    my $self = shift;
    my ($file, $info) = @_;

    $info //= $self->file_info($file);

    if (my $churn = $info->{churn}) {
        return $self->_reload_churn($file, $info);
    }

    if (my $cb = $info->{callback}) {
        my ($status, %fields) = $cb->($file);
        return ($status, %fields) if defined $status;
    }

    return $self->do_reload($file);
}

sub _reload_churn {
    my $self = shift;
    my ($file, $info) = @_;

    my $mod = $info->{module};

    for my $item (@{$info->{churn}}) {
        my ($start, $code, $end) = @$item;
        my $sline = $start + 1;
        my $src = "package $mod;\nuse strict;\nuse warnings;\nno warnings 'redefine';\n#line $sline $file\n$code\n;1;";
        my $ok = eval $src;
        warn "$$ $0 - Error reloading churn block ($file lines $start -> $end): $@\n"
            unless $ok;
    }

    return (1);
}

sub do_reload {
    my $self = shift;
    my ($file) = @_;

    my $info = $self->file_info($file);
    my $mod  = $info->{module};

    my @warnings;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @warnings => @_ };

        # Moose metaclass-aware reload wins over the generic path.
        if ($info->{is_moose} && _moose_reloader_available()) {
            require Test2::Harness2::Reloader::Moose;
            return Test2::Harness2::Reloader::Moose->reload($file, $info);
        }

        # Exporter-aware reload (replays tracked imports after reload).
        if ($info->{has_import} && _exporter_reloader_available()) {
            require Test2::Harness2::Reloader::Exporter;
            return Test2::Harness2::Reloader::Exporter->reload($file, $info);
        }

        # Generic: clear the stash and require again.
        if ($mod) {
            my $stash = do { no strict 'refs'; \%{"${mod}\::"} };
            for my $sym (keys %$stash) {
                next if $sym =~ m/::$/;
                delete $stash->{$sym};
            }
        }

        delete $INC{$info->{inc_entry}} if $info->{inc_entry};
        delete $INC{$file};

        local $.;
        require $file;

        $INC{$file}             //= $file;
        $INC{$info->{inc_entry}} //= $file if $info->{inc_entry};

        1;
    };
    my $err = $@;

    return (0, reason => $err) unless $ok;
    return (0, reason => "Got warnings during reload: " . join("\n" => @warnings)) if @warnings;
    return (1);
}

sub find_churn {
    my $self = shift;
    my ($file) = @_;

    my $fh;
    for (1 .. 50) {
        last if open $fh, '<', $file;
        Time::HiRes::sleep(0.1) if $INC{'Time/HiRes.pm'};
    }
    return unless $fh;

    my $active  = 0;
    my $line_no = 0;
    my @out;

    while (my $line = <$fh>) {
        $line_no++;

        if ($active) {
            if ($line =~ m/^\s*#\s*HARNESS-CHURN-STOP\s*$/) {
                push @{$out[-1]} => $line_no;
                $active = 0;
                next;
            }
            $out[-1][1] .= $line;
            next;
        }

        if ($line =~ m/^\s*#\s*HARNESS-CHURN-START\s*$/) {
            $active = 1;
            push @out => [$line_no, ''];
        }
    }

    close $fh;

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader - Detect file changes in a preload stage and
reload (or request a stage restart) in place.

=head1 DESCRIPTION

Each running preload stage may carry a reloader. The reloader watches files
that were loaded into the stage (plus any extras the stage registered a
C<watch> callback on) and, when a change is detected, either reloads the
file in-place or reports back that the stage must be restarted.

Two backends are provided:

=over 4

=item L<Test2::Harness2::Reloader::Inotify2>

Preferred on Linux when C<Linux::Inotify2> is installed. Selected
automatically by the factory in C<new>.

=item L<Test2::Harness2::Reloader::Stat>

Portable fallback using C<stat>-based polling.

=back

Two optional plug-in reload helpers improve the in-place path for common
cases that the generic "clear the stash + re-require" approach mishandles:

=over 4

=item L<Test2::Harness2::Reloader::Moose>

Uses C<Moose::Util::MetaRole> to fully reinitialize the metaclass so
accessors, roles and method modifiers are rebuilt correctly.

=item L<Test2::Harness2::Reloader::Exporter>

Replays tracked imports after reload so callers that took exported names
continue to see the new sub refs.

=back

=head1 SYNOPSIS

    use Test2::Harness2::Reloader;
    my $r = Test2::Harness2::Reloader->new(stage => $stage, in_place => 1);
    $r->set_active;    # exposes it to DSL watch() calls
    $r->start;

    # ... later ...
    if (my $broken = $r->check_reload) {
        # One or more files could not be reloaded; stage needs restart.
    }

=head1 ATTRIBUTES

=over 4

=item restrict => \@dirs

Only watch files under the listed directories.

=item stage => $stage_obj_or_name

The L<Test2::Harness2::Preload::Stage> this reloader belongs to. May also be
a plain string for the name.

=item in_place => BOOL

Whether in-place reloading is permitted. When false, any change causes the
stage to request a restart.

=back

=head1 METHODS

=over 4

=item $r->start

Seed the watched file set from C<%INC> and from the stage's C<watches>.

=item $r->stop

Drop all watches.

=item $r->watch($file, $cb?)

Register an additional file for watching, optionally with a callback to
invoke on change instead of attempting a normal reload.

=item $broken_or_undef = $r->check_reload

Poll for changes. Reloads everything that can be reloaded in place. Returns
an arrayref of module names that could not be reloaded (caller should
restart the stage), or undef when no restart is needed.

=item $r->set_active

Stash C<$r> as the process-wide active reloader. The DSL's C<watch()>
helper consults this when called outside a C<stage> block.

=item $r = Test2::Harness2::Reloader->ACTIVE

Return the active reloader, if any. Weakly held.

=back

=head1 BACKEND CONTRACT

Subclasses must implement:

=over 4

=item $r->do_watch($file, $val)

Register an OS-level watch for C<$file>. Return the stored watch value (the
callback or C<1>).

=item $arrayref = $r->changed_files

Return an arrayref of paths that have changed since the last call, or a
false value when nothing has changed.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
