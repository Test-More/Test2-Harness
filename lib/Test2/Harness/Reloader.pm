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
