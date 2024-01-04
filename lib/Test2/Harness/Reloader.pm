package Test2::Harness::Reloader;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken/;

use Test2::Harness::Util qw/clean_path file2mod open_file/;
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
    <in_place
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

    print STDERR "$$ $0 - Runner detected a change in one or more preloaded modules...\n";
    my @to_reload;

    for my $file (sort @$changed) {
        print STDERR "$$ $0 - Runner detected changes in file '$file'...\n";

        # Force a restart
        my ($status, %fields) = $self->can_reload_file($file);
        if (!$status) {
            $fields{reason} //= "No reason given";
            print STDERR "$$ $0 - Cannot reload file '$file' in place: $fields{reason}\n  Restarting Stage '$self->{+STAGE_NAME}'...\n";
            return 1;
        }
        if ($status < 0) {
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
            print STDERR "$$ $0 - Cannot reload file '$file' in place: $fields{reason}\n  Restarting Stage '$self->{+STAGE_NAME}'...\n";
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
    my ($file) = @_;

    my $info = $self->file_info($file);

    return (1) if $info->{churn};
    return (1) if $info->{callback};

    return (-1, reason => "In-place reloading is disabled (enable with --reload)") unless $self->{+IN_PLACE};

    return (0, reason => "$file is not a perl module, and no callback was provided for reloading it") unless $info->{perl};

    my $mod = $info->{module} or return (0, reason => "Unable to find the package associated with file '$file'");

    return (0, reason => "Module $mod is a yath preload module") if $info->{t2_preload};
    return (0, reason => "Module $mod has an import() method")   if $info->{has_import};

    return (1);
}

sub reload_file {
    my $self = shift;
    my ($file) = @_;

    my $info = $self->file_info($file);
    if (my $churn = $info->{churn}) {
        print STDERR "$$ $0 - Changed file '$file' contains churn sections, running them instead of a full reload...\n";

        my $mod = $info->{module};

        for my $item (@$churn) {
            my ($start, $code, $end) = @$item;
            my $sline = $start + 1;
            if (eval "package $mod;\nuse strict;\nuse warnings;\nno warnings 'redefine';\n#line $sline $file\n$code\n ;1;") {
                print "$$ $0 - Success reloading churn block ($file lines $start -> $end)\n";
            }
            else {
                print "$$ $0 - Error reloading churn block ($file lines $start -> $end): $@\n";
            }
        }

        return(1);
    }

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
