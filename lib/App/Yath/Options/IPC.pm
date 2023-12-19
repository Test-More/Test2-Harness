package App::Yath::Options::IPC;
use strict;
use warnings;
use feature 'state';

our $VERSION = '2.000000';

use File::Spec();
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Sys::Hostname qw/hostname/;
use Test2::Harness::Util qw/find_libraries mod2file clean_path chmod_tmp fqmod/;
use Test2::Harness::IPC::Util qw/pid_is_running/;

use Getopt::Yath;
include_options(
    'App::Yath::Options::Yath',
);

sub ipc_dirs {
    my ($settings) = @_;

    my @stat = stat($settings->yath->base_dir);

    return (
        base => File::Spec->catdir($settings->yath->base_dir, '.yath-ipc', hostname()),
        temp => File::Spec->catdir(File::Spec->tmpdir(), join('-' => 'yath-ipc', $ENV{USER}, @stat[0,1])),
    );
}

option_group {group => 'ipc', category => 'IPC Options'} => sub {
    option dir_order => (
        name => 'ipc-dir-order',
        type => 'List',
        description => "When finding ipc-dir automatically, search in this order, default: ['base', 'temp']",
        default => sub { qw/base temp/ },
    );

    option dir => (
        name => 'ipc-dir',
        type => 'Scalar',
        description => "Directory for ipc files",
    );

    option prefix => (
        name => 'ipc-prefix',
        type => 'Scalar',
        description => "Prefix for ipc files",
        default => sub { 'IPC' },
    );

    option protocol => (
        name    => 'ipc-protocol',
        type    => 'Scalar',

        long_examples => [' AtomicPipe', ' +Test2::Harness::IPC::Protocol::AtomicPipe', ' UnixSocket', ' IPSocket'],
        description   => 'Specify what IPC Protocol to use. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness::IPC::Protocol::XXX namespace is assumed.',

        normalize => sub { fqmod($_[0], 'Test2::Harness::IPC::Protocol') },
    );

    option address => (
        name => 'ipc-address',
        alt => ['ipc-file'],
        type => 'Scalar',
        description => 'IPC address (or file) to use (usually auto-generated or discovered)',
    );

    option port => (
        name => 'ipc-port',
        type => 'Scalar',
        description => 'Some IPC protocols require a port, otherwise this should be left empty',
    );

    option peer_pid => (
        name => 'ipc-peer-pid',
        type => 'Scalar',
        description => 'Optionally a peer PID may be provided',
    );

    option allow_multiple => (
        name => 'ipc-allow-multiple',
        type => 'Bool',
        default => 0,
        description => 'Normally yath will prevent you from starting multiple persistent runners in the same project, this option will allow you to start more than one.',
    );
};

sub find_ipc {
    my $class = shift;
    my ($settings, $dirs) = @_;

    $dirs //= $class->find_ipc_dirs($settings);

    my $pre = $settings->ipc->prefix;

    my %found;

    for my $dir (@$dirs) {
        opendir(my $dh, $dir) or next;
        for my $file (readdir($dh)) {
            #                                TYPE   PID  PROT      PORT
            next unless $file =~ m/^\Q$pre\E-(t|p)-(\d+)-(\w+)(?::(\d+))?$/;
            my ($type, $pid, $prot, $port) = ($1, $2, $3, $4);

            my $full = File::Spec->catfile($dir, $file);
            if (pid_is_running($pid)) {
                push @{$found{$type}} => [$full, $prot, $port, $pid];
            }
            else {
                print "Detected stale runner file: $full\n Deleting...\n";
                unlink($full);
            }
        }
        closedir($dh);
    }

    return \%found;
}

sub find_persistent_runner {
    my $class = shift;
    my ($settings) = @_;

    my $dirs = $class->find_ipc_dirs($settings);
    my $found = $class->find_ipc($settings, $dirs);

    my ($one) = @{$found->{p} // []};
    return undef unless $one;

    my %ipc;
    @ipc{qw/address protocol port peer_pid/} = @$one;
    return \%ipc;
}

sub find_ipc_dirs {
    my $class = shift;
    my ($settings) = @_;

    my $ipc_dir = $settings->ipc->dir;
    my %search  = ipc_dirs($settings);
    my @dirs    = $ipc_dir ? ($ipc_dir) : (map { $search{$_} // die "'$_' is not a valid ipc dir to check.\n" } @{$settings->ipc->dir_order});

    return \@dirs;
}

sub vivify_ipc {
    my $class = shift;
    my ($settings) = @_;

    state $discovered;
    state %ipc;
    return {%ipc} if $discovered;

    my $pre = $settings->ipc->prefix;

    my $starts  = 0;
    my $persist = 0;
    if (my $command = $settings->maybe(yath => 'command')) {
        $starts  = 1 if $command->starts_runner;
        $persist = 1 if $command->starts_persistent_runner;
    }

    my $dirs = $class->find_ipc_dirs($settings);
    my %found = %{$class->find_ipc($settings, $dirs)};
    my $found_persist = scalar @{$found{p} // []};

    if ($starts){
        die "\nExisting persistent runner(s) detected, and --ipc-allow-multiple was not specified:\n" . join("\n", map {"  PID $_->[3]: $_->[0]"} @{$found{p}}) . "\n\n"
            if $persist && $found_persist && !$settings->ipc->allow_multiple;

        $ipc{protocol} = $settings->ipc->protocol // 'Test2::Harness::IPC::Protocol::AtomicPipe';
        my $short = $ipc{protocol} =~ m/^Test2::Harness::IPC::Protocol::(.+)$/ ? $1 : "+$ipc{protocol}";
        eval { require(mod2file($ipc{protocol})); 1 } or die "\nFailed to load IPC protocol ($short): $@\n";

        $ipc{port} = $settings->ipc->port // $ipc{protocol}->default_port;

        $ipc{protocol}->verify_port($ipc{port});

        $ipc{address} = join "-" => ($pre, $persist ? 'p' : 't', $$, $short);
        $ipc{address} .= ":$ipc{port}" if length($ipc{port});

        my ($dir) = @$dirs;
        unless (-d $dir) {
            make_path($dir) or die "Could not make path '$dir'";
        }
        $ipc{address} = clean_path(File::Spec->catfile($dir, $ipc{address}));

        die "Would create fifo '$ipc{address}' but it already exists!" if -e $ipc{address};

        print "Creating instance FIFO: $ipc{address}\n";

        $discovered = 1;
        return {%ipc};
    }

    if ($found_persist > 1) {
        die "\nMultiple persistent runners detected, please select one using one of the following options:\n" . join("\n", map {"  --ipc-file '$_->[0]'"} @{$found{p}}) . "\n\n";
    }
    elsif (!$found_persist) {
        die "\nNo persistent runners detected, please use the `yath start` command to launch one.\n\n"
    }

    ($discovered) = @{$found{p}};
    @ipc{qw/address protocol port peer_pid/} = @$discovered;
    $ipc{address} = clean_path($ipc{address});

    eval { $ipc{protocol} = fqmod($ipc{protocol}, 'Test2::Harness::IPC::Protocol'); 1 }
        or die "\nFailed to load IPC protocol ($ipc{protocol}) specified by IPC file ($ipc{address}): $@\n";

    print "Found instance FIFO: $ipc{address}\n";
    return {%ipc};
}

1;

__END__



