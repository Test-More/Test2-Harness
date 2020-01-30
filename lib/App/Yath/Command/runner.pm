package App::Yath::Command::runner;
use strict;
use warnings;

our $VERSION = '1.000000';

use File::Spec;
use goto::file();
use Test2::Harness::IPC();

use Carp qw/confess/;
use Config qw/%Config/;
use Scalar::Util qw/openhandle/;
use List::Util qw/first/;
use File::Path qw/remove_tree/;

use Scope::Guard;

use Test2::Util qw/clone_io/;

use Long::Jump qw/setjump longjump/;

use Test2::Harness::Util qw/mod2file write_file_atomic open_file/;

use Test2::Harness::Util::IPC qw/swap_io/;

use Test2::Harness::Runner::Preloader();

# If FindBin is installed, go ahead and load it. We do not care much about
# success vs failure here.
BEGIN {
    local $@;
    eval { require FindBin; FindBin->import };
}

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub internal_only { 1 }
sub summary       { "For internal use only" }
sub name          { 'runner' }

sub init { confess(ref($_[0]) . " is not intended to be instantiated") }
sub run  { confess(ref($_[0]) . " does not implement run()") }

sub generate_run_sub {
    my $class = shift;
    my ($symbol, $argv, $spawn_settings) = @_;
    my ($dir, %args) = @$argv;

    $0 = $ENV{NESTED_YATH} ? 'yath-nested-runner' : 'yath-runner';

    my $settings = App::Yath::Settings->new(File::Spec->catfile($dir, 'settings.json'));

    my $cleanup = $class->cleanup($settings, \%args, $dir);

    my $runner_pid = $$;
    my $jump = setjump "Test-Runner" => sub {
        local $.;
        my @SIGNAMES = grep { $_ ne 'ZERO' } split /\s+/, $Config{sig_name};
        local @SIG{ @SIGNAMES } = @SIG{ @SIGNAMES };

        my $runner = $settings->build(
            runner => 'Test2::Harness::Runner',

            %args,

            dir      => $dir,
            settings => $settings,

            fork_job_callback       => sub { $class->launch_via_fork(@_) },
            respawn_runner_callback => sub { return unless $$ == $runner_pid; longjump "Test-Runner" => 'respawn' },
        );

        my $exit = $runner->process();

        my $complete = File::Spec->catfile($dir, 'complete');
        write_file_atomic($complete, '1');

        exit($exit // 1);
    };

    die "Test runner completed, but failed to exit" unless $jump;

    my ($action, $job, $stage) = @$jump;

    if($action eq 'respawn') {
        print "$$ Respawning the runner...\n";
        $cleanup->dismiss(1);
        exec($^X, $settings->yath->script, @{$spawn_settings->yath->orig_argv});
        warn "exec failed!";
        exit 1;
    }

    die "Invalid action: $action" if $action ne 'run_test';

    goto::file->import($job->rel_file);
    $class->cleanup_process($job, $stage);
}

sub cleanup {
    my $class = shift;
    my ($settings, $args, $dir) = @_;

    my $pfile = $args->{persist} or return;

    my $pid = $$;
    return Scope::Guard->new(sub {
        return unless $pid == $$;

        unlink($pfile);

        remove_tree($dir, {safe => 1, keep_root => 0}) unless $settings->debug->keep_dirs;
    });
}

sub get_stage {
    my $class = shift;
    my ($runner) = @_;

    return unless $runner->can('stage');

    my $stage_name = $runner->stage     or return;
    my $preloader  = $runner->preloader or return;
    my $p          = $preloader->staged or return;

    return $p->stage_lookup->{$stage_name};
}

sub launch_via_fork {
    my $class = shift;
    my ($runner, $job) = @_;

    my $stage = $class->get_stage($runner);

    $stage->do_pre_fork($job) if $stage;

    my $pid = fork();
    die "Failed to fork: $!" unless defined $pid;

    # In parent
    return $pid if $pid;

    # In Child
    my $ok = eval {
        $0 = 'yath-pending-test';
        setpgrp(0, 0) if Test2::Harness::IPC::USE_P_GROUPS();
        $runner->stop();

        $stage->do_post_fork($job) if $stage;

        longjump "Test-Runner" => ('run_test', $job, $stage);

        1;
    };
    my $err = $@;
    eval { warn $err } unless $ok;
    exit(1);
}

sub cleanup_process {
    my $class = shift;
    my ($job, $stage) = @_;

    $class->update_io($job);           # Get the correct filehandles in place early
    $class->set_env($job);             # Set up the necessary env vars
    $class->build_init_state($job);    # Lots of 'misc' stuff.
    $class->do_loads($job);            # Modules that we wanted loaded/imported post fork
    $class->test2_state($job);         # Normalize the Test2 state

    $stage->do_pre_launch($job) if $stage;

    $class->final_state($job); # Important final cleanup
}

sub test2_state {
    my $class = shift;
    my ($job) = @_;

    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stop_preload();
        Test2::API::test2_post_preload_reset();
    }

    if ($job->event_uuids) {
        require Test2::Plugin::UUID;
        Test2::Plugin::UUID->import();
    }

    if ($job->mem_usage) {
        require Test2::Plugin::MemUsage;
        Test2::Plugin::MemUsage->import();
    }

    if ($job->use_stream) {
        $ENV{T2_FORMATTER} = 'Stream';
        require Test2::Formatter::Stream;
        Test2::Formatter::Stream->import(dir => $job->event_dir, job_id => $job->job_id);
    }

    return;
}

sub final_state {
    my $class = shift;
    my ($job) = @_;

    @ARGV = $job->args;

    # toggle -w switch late
    $^W = 1 if $job->use_w_switch;

    # reset the state of empty pattern matches, so that they have the same
    # behavior as running in a clean process.
    # see "The empty pattern //" in perlop.
    # note that this has to be dynamically scoped and can't go to other subs
    "" =~ /^/;

    return;
}

sub do_loads {
    my $class = shift;
    my ($job) = @_;

    local $@;
    my $importer = eval <<'    EOT' or die $@;
package main;
#line 0 "-"
sub { $_[0]->import(@{$_[1]}) }
    EOT

    for my $set ($job->load_import) {
        my ($mod, $args) = @$set;
        my $file = mod2file($mod);
        local $0 = '-';
        require $file;
        $importer->($mod, $args);
    }

    for my $mod ($job->load) {
        my $file = mod2file($mod);
        local $0 = '-';
        require $file;
    }

    return;
}

sub build_init_state {
    my $class = shift;
    my ($job) = @_;

    if (my $chdir = $job->ch_dir) {
        chdir($chdir) or die "Could not chdir: $!";
    }

    $0 = $job->rel_file;
    $class->_reset_DATA();
    @ARGV = ();

    srand();    # avoid child processes sharing the same seed value as the parent

    # Make sure our specified includes are at the front of the list.
    my %seen;
    @INC = grep { !$seen{$_}++ } $job->unsafe_inc ? ('.') : (), $job->includes, @INC;

    # if FindBin is preloaded, reset it with the new $0
    FindBin::init() if defined &FindBin::init;

    # restore defaults
    Getopt::Long::ConfigDefaults() if defined &Getopt::Long::ConfigDefaults;

    return;
}

sub set_env {
    my $class = shift;
    my ($job) = @_;

    my $env = $job->env_vars;
    {
        no warnings 'uninitialized';
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    $ENV{T2_HARNESS_FORKED}  = 1;
    $ENV{T2_HARNESS_PRELOAD} = 1;

    return;
}

sub update_io {
    my $class = shift;
    my ($job) = @_;

    my $out_fh = open_file($job->out_file, '>');
    my $err_fh = open_file($job->err_file, '>');
    my $in_fh  = open_file($job->in_file,  '<');

    $out_fh->autoflush(1);
    $err_fh->autoflush(1);

    # Keep a copy of the old STDERR for a while so we can still report errors
    my $stderr = clone_io(\*STDERR);

    my $die = sub {
        my @caller = caller;
        my @caller2 = caller(1);
        my $msg = "$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2]).\n";
        print $stderr $msg;
        print STDERR $msg;
        POSIX::_exit(127);
    };

    swap_io(\*STDIN,  $in_fh,  $die);
    swap_io(\*STDOUT, $out_fh, $die);
    swap_io(\*STDERR, $err_fh, $die);

    return;
}

# Heavily modified from forkprove
sub _reset_DATA {
    my $class = shift;

    for my $set (@{$class->preload_list}) {
        my ($mod, $file, $pos) = @$set;

        my $fh = do {
            no strict 'refs';
            *{$mod . '::DATA'};
        };

        # note that we need to ensure that each forked copy is using a
        # different file handle, or else concurrent processes will interfere
        # with each other

        close $fh if openhandle($fh);

        if (open $fh, '<', $file) {
            seek($fh, $pos, 0);
        }
        else {
            warn "Couldn't reopen DATA for $mod ($file): $!";
        }
    }
}

# Heavily modified from forkprove
sub preload_list {
    my $class = shift;

    my $list = [];

    for my $loaded (keys %INC) {
        next unless $loaded =~ /\.pm$/;

        my $mod = $loaded;
        $mod =~ s{/}{::}g;
        $mod =~ s{\.pm$}{};

        my $fh = do {
            no strict 'refs';
            no warnings 'once';
            *{$mod . '::DATA'};
        };

        next unless openhandle($fh);
        push @$list => [$mod, $INC{$loaded}, tell($fh)];
    }

    return $list;
}


1;

__END__

=head1 POD IS AUTO-GENERATED

