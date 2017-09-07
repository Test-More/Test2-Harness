package App::Yath::Command::persist;
use strict;
use warnings;

our $VERSION = '0.001007';

use POSIX ":sys_wait_h";
use Cwd qw/realpath/;
use File::Path qw/remove_tree/;

use File::Spec();

use Test2::Harness::Feeder::Run;
use Test2::Harness::Run::Runner;
use Test2::Harness::Run;
use Test2::Harness::Util::File::JSON;

use Test2::Harness::Util qw/open_file/;

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase qw/-_feeder -_runner -_pid/;

sub has_jobs    { 1 }
sub has_runner  { 1 }
sub has_logger  { 1 }
sub has_display { 1 }
sub always_keep_dir { 1 }
sub manage_runner { 0 }

sub summary { "persistent test runner" }
sub cli_args { "start", "stop", "which", "reload", "run path/to/test.t [more test files]" }

sub description {
    return <<"    EOT";
foo bar baz
    EOT
}

sub run {
    my $self = shift;

    $self->pre_run();

    my $settings = $self->{+SETTINGS};

    my $args = $self->{+SETTINGS}->{search};
    my $cmd  = shift @$args;

    return $self->start(@$args)     if $cmd eq 'start';
    return $self->stop(@$args)      if $cmd eq 'stop';
    return $self->which(@$args)     if $cmd eq 'which';
    return $self->reload(@$args)    if $cmd eq 'reload';
    return $self->run_tests(@$args) if $cmd eq 'run';

    die "Invalid command: $cmd\n";
}

sub PFILE_NAME() { '.yath-persist.json' }

sub find_pfile {
    my $self = shift;
    my $pfile = $self->_find_pfile or return;
    return File::Spec->rel2abs($pfile);
}

sub _find_pfile {
    my $path = PFILE_NAME();
    return File::Spec->rel2abs($path) if -f $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = File::Spec->rel2abs($path);
        last if $seen{realpath($check)}++;
        return $check if -f $check;
    }

    return;
}

sub reload {
    my $self = shift;

    my $pfile = $self->find_pfile
        or die "Could not find " . PFILE_NAME . " in current directory, or any parent directories.\n";

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    print "\nSending SIGHUP to $data->{pid}\n\n";
    kill('HUP', $data->{pid}) or die "Could not send signal!\n";
    return 0;
}

sub which {
    my $self = shift;

    my $pfile = $self->find_pfile;

    unless ($pfile) {
        print "\nNo persistent harness was found for the current path.\n\n";
        return 0;
    }

    print "\nFound: $pfile\n";
    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
    print "  PID: $data->{pid}\n";
    print "  Dir: $data->{dir}\n";
    print "\n";

    return 0;
}

sub stop {
    my $self = shift;

    my $pfile = $self->find_pfile
        or die "Could not find " . PFILE_NAME . " in current directory, or any parent directories.\n";

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    my $exit;
    if (kill('TERM', $data->{pid})) {
        waitpid($data->{pid}, 0);
        $exit = 0;
    }
    else {
        warn "Could not kill pid $data->{pid}.\n";
        $exit = 255;
    }

    unlink($pfile) if -f $pfile;

    my $stdout = open_file(File::Spec->catfile($data->{dir}, 'output.log'));
    my $stderr = open_file(File::Spec->catfile($data->{dir}, 'error.log'));

    print "\nSTDOUT LOG:\n";
    print "========================\n";
    while( my $line = <$stdout> ) {
        print $line;
    }
    print "\n========================\n";

    print STDERR "\nSTDERR LOG:\n";
    print STDERR "========================\n";
    while (my $line = <$stderr>) {
        print STDERR $line;
    }
    print STDERR "\n========================\n";

    remove_tree($data->{dir}, {safe => 1, keep_root => 0});

    print "\n";
    return $exit;
}

sub start {
    my $self = shift;

    if (my $exists = $self->find_pfile) {
        die "Persistent harness appears to be running, found $exists\n"
    }

    my $settings = $self->{+SETTINGS};
    my $pfile = File::Spec->rel2abs(PFILE_NAME());

    my ($exit, $runner, $pid, $stat);
    my $ok = eval {
        my $run = $self->make_run_from_settings(finite => 0, keep_dir => 1);

        $runner = Test2::Harness::Run::Runner->new(
            dir => $settings->{dir},
            run => $run,
        );

        my $queue = $runner->queue;
        $queue->start;

        $pid = $runner->spawn(setsid => 1, pfile => $pfile);

        1;
    };
    my $err = $@;

    my $sig = $self->{+SIGNAL};

    print STDERR $err if !$ok && !$sig;
    print STDERR "Received SIG$sig\n" if $sig;

    print "Waiting for runner...\n";

    sleep 1;
    my $check = waitpid($pid, WNOHANG);
    if ($check != 0) {
        my $exit = $?;
        my $sig = $? & 127;
        $exit >>= 8;
        print STDERR "\nProblem with runner ($pid), waitpid returned $check, exit value: $exit Signal: $sig\n";

        my $stdout = open_file($runner->out_log);
        my $stderr = open_file($runner->err_log);

        while( my $line = <$stdout> ) {
            print STDOUT $line;
        }
        while (my $line = <$stderr>) {
            print STDERR $line;
        }
    }
    else {
        print "\nPersistent runner started!\n";

        print "Runner PID: $pid\n";
        print "Runner dir: $settings->{dir}\n";
        print "Runner logs:\n";
        print "  standard output: " . $runner->out_log. "\n";
        print "  standard  error: " . $runner->err_log. "\n";
        print "\n";

        my $data = {
            pid => $pid,
            dir => $settings->{dir},
        };

        Test2::Harness::Util::File::JSON->new(name => $pfile)->write($data);
    }

    return $sig ? 255 : ($exit || 0);
}

sub run_tests {
    my $self = shift;
    my @search = @_;

    my $settings = $self->{+SETTINGS};

    my $pfile = $self->find_pfile
        or die "Could not find " . PFILE_NAME . " in current directory, or any parent directories.\n";

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    my $runner = Test2::Harness::Run::Runner->new(
        dir => $data->{dir},
        pid => $data->{pid},
    );

    my $run = $runner->run;

    my $queue = $runner->queue;

    $run->{search} = \@search;

    my %jobs;
    my $base_id = 1;
    for my $file ($run->find_files) {
        my $job_id = $$ . '-' . $base_id++;
        $file = File::Spec->rel2abs($file);
        my $tf = Test2::Harness::Util::TestFile->new(file => $file);

        my $category = $tf->check_category;

        my $fork    = $tf->check_feature(fork      => 1);
        my $preload = $tf->check_feature(preload   => 1);
        my $timeout = $tf->check_feature(timeout   => 1);
        my $isolate = $tf->check_feature(isolation => 0);
        my $stream  = $tf->check_feature(stream    => 1);

        if (!$category) {
            # 'isolation' queue if isolation requested
            $category = 'isolation' if $isolate;

            # 'long' queue for anything that cannot preload or fork
            $category ||= 'medium' unless $preload && $fork;

            # 'long' for anything with no timeout
            $category ||= 'long' unless $timeout;

            # Default
            $category ||= 'general';
        }

        my $item = {
            file        => $file,
            use_fork    => $fork,
            use_timeout => $timeout,
            use_preload => $preload,
            use_stream  => $stream,
            switches    => $tf->switches,
            category    => $category,
            stamp       => time,
            job_id      => $job_id,
            libs        => [$run->all_libs],
        };

        $item->{args}        = $settings->{pass}        if defined $settings->{pass};
        $item->{times}       = $settings->{times}       if defined $settings->{times};
        $item->{use_stream}  = $settings->{use_stream}  if defined $settings->{use_stream};
        $item->{load}        = $settings->{load}        if defined $settings->{load};
        $item->{load_import} = $settings->{load_import} if defined $settings->{load_import};
        $item->{use_timeout} = $settings->{use_timeout} if defined $settings->{use_timeout};
        $item->{env_vars}    = $settings->{env_vars}    if defined $settings->{env_vars};
        $item->{input}       = $settings->{input}       if defined $settings->{input};
        $item->{chdir}       = $settings->{chdir}       if defined $settings->{chdir};

        $queue->enqueue($item);
        $jobs{$job_id} = 1;
    }

    my $feeder = Test2::Harness::Feeder::Run->new(
        run      => $run,
        runner   => $runner,
        dir      => $data->{dir},
        keep_dir => 0,
        job_ids  => \%jobs,
    );

    $self->{+_FEEDER} = $feeder;
    $self->{+_RUNNER} = $runner;
    $self->{+_PID}    = $data->{pid};
    $self->SUPER::_run();
}

sub feeder {
    my $self = shift;

    return ($self->{+_FEEDER}, $self->{+_RUNNER}, $self->{+_PID});
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::persist

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
