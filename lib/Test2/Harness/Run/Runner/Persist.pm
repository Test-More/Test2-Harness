package Test2::Harness::Run::Runner::Persist;
use strict;
use warnings;

use Test2::Util qw/pkg_to_file/;

our $VERSION = '0.001015';

use parent 'Test2::Harness::Run::Runner';
use Test2::Harness::Util::HashBase qw/-inotify -stats -dep_map/;

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

# If we are stating files on the drive we should only poll every 2 seconds. If
# we have Inotify we can use the normal 0.02
sub wait_time { USE_INOTIFY() ? 0.02 : 2 }

sub init_state {
    my $self = shift;

    $self->SUPER::init_state();

    my $state = $self->{+STATE};

    $state->{block_preload} ||= {};

    return;
}

my %EXCLUDE = (
    'warnings' => 1,
    'strict'   => 1,
);

sub _preload {
    my $self = shift;
    my ($req, $block, $base_require) = @_;

    my $state = $self->{+STATE};
    $block = $block ? { %$block, %{$state->{block_preload}} } : $state->{block_preload};

    my $stash = \%CORE::GLOBAL::;
    # We use a string in the reference below to prevent the glob slot from
    # being auto-vivified by the compiler.
    my $old_require = exists $stash->{require} ? \&{'CORE::GLOBAL::require'} : undef;

    my (%dep_map, @watch);
    my $on      = 1;
    my $require = sub {
        my $file = shift;

        unless ($on) {
            return $old_require->($file) if $old_require;
            return CORE::require($file);
        }

        if ($file !~ m/^[\d\.]+$/) {
            my $pkg = file_to_pkg($file);

            unless ($EXCLUDE{$pkg}) {
                push @{$dep_map{$pkg}} => scalar(caller);
                push @watch            => $file;
            }
        }

        return $base_require->($file) if $base_require;
        return $old_require->($file)  if $old_require;
        return CORE::require($file);
    };

    {
        no strict 'refs';
        *{'CORE::GLOBAL::require'} = $require;
    }

    $self->SUPER::_preload($req, $block, $require);

    $on = 0;

    $self->{+DEP_MAP} = \%dep_map;

    $self->watch($_) for map { $INC{$_} } @watch;

    return;
}

sub hup {
    my $self = shift;

    $self->preloads_changed();

    return $self->SUPER::hup();
}

sub watch {
    my $self = shift;
    my ($file) = @_;

    if (USE_INOTIFY()) {
        my $inotify = $self->{+INOTIFY} ||= do {
            my $in = Linux::Inotify2->new;
            $in->blocking(0);
            $in;
        };

        $inotify->watch($file, INOTIFY_MASK());
    }
    else {
        my $stats = $self->{+STATS} ||= {};
        my (undef,undef,undef,undef,undef,undef,undef,undef,undef,$mtime,$ctime) = stat($file);
        $stats->{$file} = [$mtime, $ctime];
    }
}

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

sub file_to_pkg {
    my $file = shift;
    my $pkg  = $file;
    $pkg =~ s{/}{::}g;
    $pkg =~ s/\..*$//;
    return $pkg;
}

1;
