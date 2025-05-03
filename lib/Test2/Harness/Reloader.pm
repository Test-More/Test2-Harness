package Test2::Harness::Reloader;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken/;
use B();

use Test2::Harness::Util qw/clean_path file2mod open_file/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json/;

our $VERSION = '2.000005';

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

sub changed_files { croak "$_[0] does not implement 'changed_files'" }

sub init {
    my $self = shift;

    $self->{+RESTRICT} //= [];
    $self->{+WATCHES}  //= {};
    $self->{+WATCHED}  //= {};

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

sub start {
    my $self = shift;

    my $watches = $self->find_files_to_watch;
    my $watched = $self->{+WATCHED} //= {};

    for my $file (keys %$watches) {
        $watched->{$file} //= $self->do_watch($file, $watches->{$file});
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

    croak "The first argument must be a file (got: $file)" unless $file && -f $file;
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

    my $cb = $watched->{$file} or return undef;
    my $ref = ref($cb) or return undef;
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

    print STDERR "$$ $0 - Runner detected a change in one or more preloaded modules...\n";
    my @to_reload;
    my @cannot_reload;
    my $bad = 0;

    for my $file (sort @$changed) {
        print STDERR "$$ $0 - Runner detected changes in file '$file'...\n";

        my $info = $self->file_info($file);

        my ($status, %fields) = $self->can_reload_file($file, $info);
        if (!$status) {
            $fields{reason} //= "No reason given";
            print STDERR "$$ $0 - Cannot reload file '$file' in place: $fields{reason}\n  Restarting Stage '$self->{+STAGE_NAME}'...\n";
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
        unless(eval { ($status, %fields) = $self->reload_file($file, $info); 1 }) {
            %fields = (reason => $@);
            $status = 0;
        }

        unless ($status) {
            $fields{reason} //= "No reason given";
            print STDERR "$$ $0 - Cannot reload file '$file' in place: $fields{reason}\n  Restarting Stage '$self->{+STAGE_NAME}'...\n";
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

    $info->{reload_inplace_check} = $self->stage->reload_inplace_check();
    $info->{callback}             = $self->file_has_callback($file);

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

            if (my $imp = $mod->can('import')) {
                my $cobj    = B::svref_2object($imp);
                my $file    = $cobj->FILE // 'NONE';
                my $package = $cobj->GV->STASH->NAME // 'NONE';

                # Perl 5.40 adds a UNIVERSAL::import
                $info->{has_import} = 1 unless $package eq 'UNIVERSAL' || $file eq 'universal.c';
            }

            $info->{t2_preload} = $mod->can('TEST2_HARNESS_PRELOAD');
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

sub can_reload_file {
    my $self = shift;
    my ($file, $info) = @_;

    $info //= $self->file_info($file);

    return (1) if $info->{churn};
    return (1) if $info->{callback};

    return (-1, reason => "In-place reloading is disabled (enable with --reload)") unless $self->{+IN_PLACE};

    if (my $cb = $info->{reload_inplace_check}) {
        my ($res, %fields) = $cb->(%$info);
        return ($res, %fields) if defined $res;
    }

    return (0, reason => "$file is not a perl module, and no callback was provided for reloading it") unless $info->{perl};

    my $mod = $info->{module} or return (0, reason => "Unable to find the package associated with file '$file'");

    return (0, reason => "Module $mod is a yath preload module") if $info->{t2_preload};
    return (0, reason => "Module $mod has an import() method")   if $info->{has_import};

    return (1);
}

sub reload_file {
    my $self = shift;
    my ($file, $info) = @_;

    $info //= $self->file_info($file);
    if (my $churn = $info->{churn}) {
        print STDERR "$$ $0 - Changed file '$file' contains churn sections, running them instead of a full reload...\n";

        my $mod = $info->{module};

        for my $item (@$churn) {
            my ($start, $code, $end) = @$item;
            my $sline = $start + 1;
            if (eval "package $mod;\nuse strict;\nuse warnings;\nno warnings 'redefine';\n#line $sline $file\n$code\n ;1;") {
                print STDERR "$$ $0 - Success reloading churn block ($file lines $start -> $end)\n";
            }
            else {
                print STDERR "$$ $0 - Error reloading churn block ($file lines $start -> $end): $@\n";
            }
        }

        return(1);
    }

    if (my $cb = $info->{callback}) {
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

    print STDERR "$$ $0 - Runner attempting to reload '$file' in place...\n";

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

        # A reload using require of the absolute path means we need to clear
        # both the normal inc entry and an inc entry for the full path.
        delete $INC{$info->{inc_entry}};
        delete $INC{$file};

        local $.;
        require $file;

        # Make sure BOTH inc entries are set
        $INC{$file} //= $file;
        $INC{$info->{inc_entry}} //= $file;

        1;
    };
    my $err = $@;

    return (0, reason => $err) unless $ok;
    return (0, reason => "Got warnings: " . encode_pretty_json(\@warnings)) if @warnings;
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


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Reloader - FIXME

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

