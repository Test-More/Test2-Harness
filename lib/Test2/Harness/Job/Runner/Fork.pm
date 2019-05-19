package Test2::Harness::Job::Runner::Fork;
use strict;
use warnings;

our $VERSION = '0.001076';

use POSIX;
use File::Spec();
use Scalar::Util qw/openhandle/;
use Test2::Util qw/clone_io CAN_REALLY_FORK pkg_to_file/;
use Test2::Harness::Util qw/write_file/;
use Test2::Harness::Util::IPC qw/swap_io/;

sub viable {
    my $class = shift;
    my ($test) = @_;

    return 0 unless CAN_REALLY_FORK();

    return 0 if $ENV{HARNESS_PERL_SWITCHES};

    my $job = $test->job;

    return 0 if !$job->use_fork;

    # -w switch is ok, otherwise it is a no-go
    return 0 if grep { !m/\s*-w\s*/ } @{$job->switches};

    return 1;
}

sub run {
    my $class = shift;
    my ($test) = @_;

    my $job = $test->job;
    my $preloads = $job->preload || [];

    $_->pre_fork($job) for @$preloads;

    my $pid = fork();
    die "Failed to fork: $!" unless defined $pid;

    # In parent
    return ($pid, undef) if $pid;

    my %seen = (map { ($_ => 1) } @INC);

    unshift @INC => (grep { !$seen{$_}++ } (map {File::Spec->rel2abs($_)} @{$job->libs}));

    if (my $dir = $job->ch_dir) {
        chdir($dir) or die "Could not chdir: $!";
    }

    # In Child
    my $file = $job->file;

    # toggle -w switch late
    $^W = 1 if grep { m/\s*-w\s*/ } @{$job->switches};

    $SIG{TERM} = 'DEFAULT';
    $SIG{INT} = 'DEFAULT';
    $SIG{HUP} = 'DEFAULT';

    my $env = $job->env_vars;
    {
        no warnings 'uninitialized';
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    $ENV{T2_HARNESS_JOB_NAME} = $job->job_name;
    $ENV{T2_HARNESS_FORKED}   = 1;
    $ENV{T2_HARNESS_PRELOAD}  = 1;

    my ($in_file, $out_file, $err_file, $event_dir) = $test->output_filenames;

    $0 = File::Spec->abs2rel($file);
    $class->_reset_DATA($file);
    @ARGV = ();

    $_->post_fork($job) for @$preloads;

    my $importer = eval <<'    EOT' or die $@;
package main;
#line 0 "-"
sub { shift->import(@_) }
    EOT

    for my $mod (@{$job->load_import || []}) {
        my @args;
        if ($mod =~ s/=(.*)$//) {
            @args = split /,/, $1;
        }
        my $file = pkg_to_file($mod);
        local $0 = '-';
        require $file;
        $importer->($mod, @args);
    }

    for my $mod (@{$job->load || []}) {
        my $file = pkg_to_file($mod);
        require $file;
    }

    # if FindBin is preloaded, reset it with the new $0
    FindBin::init() if defined &FindBin::init;

    # restore defaults
    Getopt::Long::ConfigDefaults() if defined &Getopt::Long::ConfigDefaults;

    # reset the state of empty pattern matches, so that they have the same
    # behavior as running in a clean process.
    # see "The empty pattern //" in perlop.
    # note that this has to be dynamically scoped and can't go to other subs
    "" =~ /^/;

    # Keep a copy of the old STDERR for a while so we can still report errors
    my $stderr = clone_io(\*STDERR);

    write_file($in_file, $job->input);

    my $die = sub {
        my @caller = caller;
        my @caller2 = caller(1);
        my $msg = "$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2]).\n";
        print $stderr $msg;
        print STDERR $msg;
        POSIX::_exit(127);
    };

    swap_io(\*STDIN,  $in_file,  $die);
    swap_io(\*STDOUT, $out_file, $die);
    swap_io(\*STDERR, $err_file, $die);

    # avoid child processes sharing the same seed value as the parent
    srand();

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
        Test2::Formatter::Stream->import(dir => $event_dir);
    }

    if ($job->times) {
        require Test2::Plugin::Times;
        Test2::Plugin::Times->import();
    }

    @ARGV = @{$job->args};

    $_->pre_launch($job) for @$preloads;

    return (undef, $file);
}

# Heavily modified from forkprove
sub _reset_DATA {
    my $class = shift;
    my ($file) = @_;

    # open DATA from test script
    if (openhandle(\*main::DATA)) {
        close ::DATA;
        if (open my $fh, $file) {
            my $code = do { local $/; <$fh> };
            if (my ($data) = $code =~ /^__(?:END|DATA)__$(.*)/ms) {
                open ::DATA, '<', \$data
                    or die "Can't open string as DATA. $!";
            }
        }
    }

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

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::Runner::Fork - Logic for running a test job by forking.

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
