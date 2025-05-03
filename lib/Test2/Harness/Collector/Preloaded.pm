package Test2::Harness::Collector::Preloaded;
use strict;
use warnings;

our $VERSION = '2.000005';

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

use Test2::Harness::Util qw/mod2file parse_exit/;
use Test2::Harness::IPC::Util qw/ipc_connect set_procname/;

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

sub spawn {
    my $self = shift;
    my %params = @_;

    $self->setsid;

    my $io_pid = $params{io_pid};
    close(STDIN);
    open(STDIN, "<", "/proc/$io_pid/fd/0") or die "Could not connect to STDIN from pid $io_pid: $!";

    close(STDOUT);
    open(STDOUT, '>>', "/proc/$io_pid/fd/1") or die "Could not connect to STDOUT from pid $io_pid: $!";

    close(STDERR);
    open(STDERR, '>>', "/proc/$io_pid/fd/2") or die "Could not connect to STDOUT from pid $io_pid: $!";

    my ($ipc, $con) = ipc_connect($params{ipc});

    my $pid = fork // die "Could not fork";
    if ($pid) {
        $con->send_message({pid => $pid});

        my $check = waitpid($pid, 0);
        my $exit = $?;
        die "(Yath Collector) waitpid returned $check" unless $check == $pid;
        my $x = parse_exit($exit);

        $con->send_message({exit => $x});
        exit(0);
    }

    undef($con);
    undef($ipc);

    my $stage = $params{stage};

    $stage->do_post_fork(spawn => \%params);

    $0 = $params{script};

    require goto::file;
    goto::file->import($params{script});

    $self->restore_signals();

    my $env = $params{env} // {};
    for my $var (keys %$env) {
        no warnings 'uninitialized';
        $ENV{$var} = $env->{$var}
    }

    $self->build_init_state();
    $self->test2_state();

    $stage->do_pre_launch(spawn => \%params);

    @ARGV = @{$params{argv} // []};

    # toggle -w switch late
    open(my $fh, '<', $params{script}) or die "Could not open script '$params{script}': $!";
    my $shbang = <$fh>;
    $^W = 1 if $shbang =~ m/^#!.*\b-w\b/;
    close($fh);

    # reset the state of empty pattern matches, so that they have the same
    # behavior as running in a clean process.
    # see "The empty pattern //" in perlop.
    # note that this has to be dynamically scoped and can't go to other subs
    "" =~ /^/;

    $@ = undef;

    return;
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
        set_procname(set => ['collector', $pid]);
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
    goto::file->import($job->test_file->relative);

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

    return;
}

sub build_init_state {
    my $self = shift;

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

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Collector::Preloaded - FIXME

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

