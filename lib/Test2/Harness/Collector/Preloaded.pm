package Test2::Harness::Collector::Preloaded;
use strict;
use warnings;

our $VERSION = '2.000000';

# If FindBin is installed, go ahead and load it. We do not care much about
# success vs failure here.
BEGIN {
    local $@;
    eval { require FindBin; FindBin->import };
}

use Carp qw/croak/;
use Config qw/%Config/;
use List::Util qw/first/;
use Scalar::Util qw/openhandle/;

use Test2::Harness::Util qw/mod2file/;

my @SIGNALS = grep { $_ ne 'ZERO' } split /\s+/, $Config{sig_name};

use parent 'Test2::Harness::Collector';
use Test2::Harness::Util::HashBase qw{
    <orig_sig
    <stage
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'orig_sig' is a required attribute" unless $self->{+ORIG_SIG};
    croak "'stage' is a required attribute"    unless $self->{+STAGE};
}

sub launch_and_process {
    my $self = shift;
    my ($parent_cb, $child_cb) = @_;

    return $self->SUPER::launch_and_process(@_) if $self->{+SKIP};

    my $run   = $self->{+RUN};
    my $job   = $self->{+JOB};
    my $ts    = $self->{+TEST_SETTINGS};
    my $stage = $self->{+STAGE};

    my $parent_pid = $$;
    my $pid        = fork // die "Could not fork: $!";
    if ($pid) {
        $0 = "yath-collector $pid";
        $parent_cb->($pid) if $parent_cb;
        return $self->process($pid);
    }

    $stage->do_post_fork(
        run => $run,
        job => $job,
        parent_pid => $parent_pid,
        test_settings => $ts,
    );

    $0 = $job->test_file->relative;
    $child_cb->($parent_pid) if $child_cb;

    require goto::file;
    goto::file->import($job->test_file->file);

    unless (eval { $self->cleanup_process($parent_pid); 1 }) {
        print STDERR $@;
        exit(255);
    }

    $@ = undef;

    return;
}

sub cleanup_process {
    my $self = shift;
    my ($parent_pid);

    my $stage = $self->{+STAGE};

    $self->restore_signals();
    $self->setup_child();

    $self->build_init_state();
    $self->do_loads();
    $self->test2_state();

    $stage->do_pre_launch(
        job           => $self->{+JOB},
        run           => $self->{+RUN},
        parent_pid    => $parent_pid,
        test_settings => $self->{+TEST_SETTINGS},
    );

    $self->final_state();         # Important final cleanup

    DB::enable_profile() if $self->{+RUN}->nytprof;
}

sub restore_signals {
    my $self = shift;

    my $orig_sig = $self->{+ORIG_SIG};

    my %seen;
    for my $sig (@SIGNALS) {
        next if $seen{$sig}++;
        if (exists $orig_sig->{$sig}) {
            $SIG{$sig} = $orig_sig->{$sig};
        }
        else {
            delete $SIG{$sig};
        }
    }
}

sub setup_child_env_vars {
    my $self = shift;

    $self->SUPER::setup_child_env_vars();

    $ENV{T2_HARNESS_FORKED}  = 1;
    $ENV{T2_HARNESS_PRELOAD} = 1;

    return;
}

sub setup_child_input {
    my $self = shift;

    $self->SUPER::setup_child_input();
    #$FIX_STDIN = 1 if $in_file;

    return;
}

sub build_init_state {
    my $self = shift;

    my $job = $self->{+JOB};

    $0 = $job->test_file->relative;
    $self->_reset_DATA();
    @ARGV = ();

    srand();  # avoid child processes sharing the same seed value as the parent

    # if FindBin is preloaded, reset it with the new $0
    FindBin::init() if defined &FindBin::init;

    # restore defaults
    Getopt::Long::ConfigDefaults() if defined &Getopt::Long::ConfigDefaults;

    return;
}

# Heavily modified from forkprove
sub _reset_DATA {
    my $self = shift;

    for my $set (@{$self->preload_list}) {
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
    my $self = shift;

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

sub do_loads {
    my $self = shift;

    my $ts = $self->{+TEST_SETTINGS};

    local $@;
    my $importer = eval <<'    EOT' or die $@;
package main;
#line 0 "-"
sub { $_[0]->import(@{$_[1]}) }
    EOT

    my $load_import = $ts->load_import // {};
    for my $mod (@{$load_import->{'@'} // []}) {
        my $args = $load_import->{$mod} // [];
        my $file = mod2file($mod);
        require $file;
        $importer->($mod, $args);
    }

    for my $mod (@{$ts->load}) {
        my $file = mod2file($mod);
        require $file;
    }

    return;
}


sub test2_state {
    my $self = shift;

    my $ts = $self->{+TEST_SETTINGS};

    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stop_preload();
        Test2::API::test2_post_preload_reset();
        Test2::API::test2_enable_trace_stamps();
    }

    if ($ts->use_stream) {
        $ENV{T2_FORMATTER} = 'Stream';    # This is redundant and should already be set.
        require Test2::Formatter::Stream;
        Test2::Formatter::Stream->import();
    }
}

sub final_state {
    my $self = shift;

    my $ts = $self->{+TEST_SETTINGS};
    my $tf = $self->{+JOB}->test_file;

    @ARGV = @{$ts->args // []};

    # toggle -w switch late
    $^W = 1 if first { m/\s*-w\s*/ } @{$tf->switches // []}, @{$ts->switches // []};

    # reset the state of empty pattern matches, so that they have the same
    # behavior as running in a clean process.
    # see "The empty pattern //" in perlop.
    # note that this has to be dynamically scoped and can't go to other subs
    "" =~ /^/;

    return;
}

1;


__END__
# For some reason Filter::Util::Class breaks the STDIN filehandle. This works
# around that.
my $FIX_STDIN;
BEGIN {
    require goto::file;
    no strict 'refs';
    no warnings 'redefine';

    my $int_done;
    my $orig = goto::file->can('filter');
    *goto::file::filter = sub {
        local $.;
        my $out = $orig->(@_);
        seek(STDIN, 0, 0) if $FIX_STDIN;

        unless ($int_done++) {
            if (my $fifo = $ENV{YATH_INTERACTIVE}) {
                my $ok;
                for (1 .. 10) {
                    $ok = open(STDIN, '<', $fifo);
                    last if $ok;
                    die "Could not open fifo ($fifo): $!";
                    sleep 1;
                }

                die "Could not open fifo ($fifo): $!" unless $ok;

                print STDERR <<'                EOT';

*******************************************************************************
*                   YATH IS RUNNING IN INTERACTIVE MODE                       *
*                                                                             *
* STDIN is comming from a fifo pipe, not a TTY!                               *
*                                                                             *
* The $ENV{YATH_INTERACTIVE} var is set to the FIFO being used.               *
*                                                                             *
* VERBOSE mode has been turned on for you                                     *
*                                                                             *
* Only 1 test will run at a time                                              *
*                                                                             *
* The main yath process no longer has STDIN, so yath plugins that wait for    *
* input WILL BREAK.                                                           *
*                                                                             *
* Prompts that do not end with a newline may have a 1 second delay before     *
* they are displayed, they will be prefixed with [INTERACTIVE]                *
*                                                                             *
* Any stdin/stdout that is printed in 2 parts without a newline and more than *
* a 1 second delay will be printed with the [INTERACTIVE] prefix, if they are *
* not actually a prompt you can safely ignore them.                           *
*                                                                             *
* It is possible that a prompt was displayed before this message, please      *
* check above if your prompt appears missing. This is an IO fluke, not a bug. *
*                                                                             *
*******************************************************************************

                EOT
            }
        }

        return $out;
    };
}

use Test2::Harness::IPC();
use Test2::Harness::State;

use Carp qw/confess/;
use List::Util qw/first/;
use File::Path qw/remove_tree/;

use Test2::Util qw/clone_io/;

use Long::Jump qw/setjump longjump/;

use Test2::Harness::Util qw/mod2file write_file_atomic open_file clean_path process_includes/;

use Test2::Harness::Util::IPC qw/swap_io/;

use Test2::Harness::Runner::Preloader();


    $class->cleanup_process($job, $stage);
}

sub cleanup_process {
    my $class = shift;
    my ($job, $stage) = @_;

}

sub test2_state {
    my $class = shift;
    my ($job) = @_;

    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stop_preload();
        Test2::API::test2_post_preload_reset();
    }

    if ($job->use_stream) {
        $ENV{T2_FORMATTER} = 'Stream';
        require Test2::Formatter::Stream;
        Test2::Formatter::Stream->import(dir => $job->event_dir, job_id => $job->job_id);
    }

    if ($job->event_uuids) {
        require Test2::Plugin::UUID;
        Test2::Plugin::UUID->import();
    }

    if ($job->mem_usage) {
        require Test2::Plugin::MemUsage;
        Test2::Plugin::MemUsage->import();
    }

    if ($job->io_events) {
        require Test2::Plugin::IOEvents;
        Test2::Plugin::IOEvents->import();
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
        require $file;
        $importer->($mod, $args);
    }

    for my $mod ($job->load) {
        my $file = mod2file($mod);
        require $file;
    }

    return;
}

sub build_init_state {
    my $class = shift;
    my ($job) = @_;

    $0 = $job->rel_file;
    $class->_reset_DATA();
    @ARGV = ();

    srand();    # avoid child processes sharing the same seed value as the parent

    @INC = process_includes(
        list            => [$job->includes],
        include_dot     => $job->unsafe_inc,
        include_current => 1,
        clean           => 1,
    );

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

    my $in_file = $job->in_file;
    my $in_fh = open_file($in_file, '<') if $in_file;

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

    swap_io(\*STDIN,  $in_fh,  $die, '<&') if $in_file;
    swap_io(\*STDOUT, $out_fh, $die, '>&');
    swap_io(\*STDERR, $err_fh, $die, '>&');

    $FIX_STDIN = 1 if $in_file;

    return;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

