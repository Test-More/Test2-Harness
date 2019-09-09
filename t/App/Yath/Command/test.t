use Test2::V0 -target => 'App::Yath::Command::test';
# HARNESS-DURATION-SHORT

use ok $CLASS;

subtest simple => sub {
    is($CLASS->group, ' test', "Correct group");

    is($CLASS->has_jobs,      1, "has_jobs");
    is($CLASS->has_runner,    1, "has_runner");
    is($CLASS->has_logger,    1, "has_logger");
    is($CLASS->has_display,   1, "has_display");
    is($CLASS->manage_runner, 1, "manage_runner");

    ok($CLASS->summary, "has a summary");
    ok($CLASS->cli_args, "has cli args");
    ok($CLASS->description, "has a description");
};

#subtest options => sub {
#    
#};

done_testing;

__END__
    subtest show_opts => sub {
        my $one = $TCLASS->new(args => {});
        ok(!$one->settings->{show_opts}, "not on by default");

        my $two = $TCLASS->new(args => {opts => ['--show-opts']});
        ok($two->settings->{show_opts}, "toggled on");
    };

sub options {
    my $self = shift;

    return (
        $self->SUPER::options(),

        {
            spec    => 'default-search=s@',
            field   => 'default_search',
            used_by => {runner => 1, jobs => 1},
            section => 'Job Options',
            usage   => ['--default-search t'],
            default => sub { ['./t', './t2', 'test.pl'] },
            long_desc => "Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line",
        },

        {
            spec    => 'default-at-search=s@',
            field   => 'default_at_search',
            used_by => {runner => 1, jobs => 1},
            section => 'Job Options',
            usage   => ['--default-at-search xt'],
            default => sub { ['./xt'] },
            long_desc => "Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line",
        },
    );
}


sub handle_list_args {
    my $self = shift;
    my ($list) = @_;

    my $settings = $self->{+SETTINGS} ||= {};

    $settings->{search} = $list;

    my $has_search = $settings->{search} && @{$settings->{search}};

    unless ($has_search) {
        return if grep { $_->block_default_search($settings) } keys %{$settings->{plugins}};
        return unless $settings->{default_search};

        my @search = @{$settings->{default_search}};

        push @search => @{$settings->{default_at_search}}
            if $ENV{AUTHOR_TESTING} || $settings->{env_vars}->{AUTHOR_TESTING};

        my (@dirs, @files);
        for my $path (@search) {
            if (-d $path) {
                push @dirs => $path;
                next;
            }
            if (-f $path) {
                next if $path =~ m/test\.pl$/ && is_generated_test_pl($path);
                push @files => $path;
            }
        }

        $settings->{search} = [@dirs, @files];
    }
}

sub feeder {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $run = $self->make_run_from_settings(finite => 1);

    my $runner = Test2::Harness::Run::Runner->new(
        dir => $settings->{dir},
        run => $run,
        script => find_yath(),
    );

    my $queue = $runner->queue;
    $queue->start;

    my $job_id = 1;
    for my $tf ($run->find_files) {
        $queue->enqueue($tf->queue_item($job_id++));
    }

    my $pid = $runner->spawn(jobs_todo => $job_id - 1);

    $queue->end;

    my $feeder = Test2::Harness::Feeder::Run->new(
        run      => $run,
        runner   => $runner,
        dir      => $settings->{dir},
        keep_dir => $settings->{keep_dir},
    );

    return ($feeder, $runner, $pid, $job_id - 1);
}

sub run_command {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $renderers = $self->renderers;
    my $loggers   = $self->loggers;

    my ($feeder, $runner, $pid, $stat, $jobs_todo);
    my $ok = eval {
        ($feeder, $runner, $pid, $jobs_todo) = $self->feeder or die "No feeder!";

        my $harness = Test2::Harness->new(
            run_id            => $settings->{run_id},
            live              => $pid ? 1 : 0,
            feeder            => $feeder,
            loggers           => $loggers,
            renderers         => $renderers,
            event_timeout     => $settings->{event_timeout},
            post_exit_timeout => $settings->{post_exit_timeout},
            jobs              => $settings->{jobs},
            jobs_todo         => $jobs_todo,
        );

        $stat = $harness->run();

        1;
    };
    my $err = $@;
    warn $err unless $ok;

    my $exit = 0;

    if ($self->manage_runner) {
        unless ($ok) {
            if ($pid) {
                print STDERR "Killing runner\n";
                kill($self->{+SIGNAL} || 'TERM', $pid);
            }
        }

        if ($runner && $runner->pid) {
            $runner->wait;
            $exit = $runner->exit;
        }
    }

    if (-t STDOUT) {
        print STDOUT Term::ANSIColor::color('reset') if USE_ANSI_COLOR;
        print STDOUT "\r\e[K";
    }

    if (-t STDERR) {
        print STDERR Term::ANSIColor::color('reset') if USE_ANSI_COLOR;
        print STDERR "\r\e[K";
    }

    $self->paint("\n", '=' x 80, "\n");
    $self->paint("\nRun ID: $settings->{run_id}\n");

    my $bad = $stat ? $stat->{fail} : [];
    my $lost = $stat ? $stat->{lost} : 0;

    # Possible failure causes
    my $fail = $lost || $exit || !defined($exit) || !$ok || !$stat;

    if (@$bad) {
        $self->paint("\nThe following test jobs failed:\n");
        $self->paint("  [", $_->{job_id}, '] ', File::Spec->abs2rel($_->file), "\n") for sort {
            my $an = $a->{job_id};
            $an =~ s/\D+//g;
            my $bn = $b->{job_id};
            $bn =~ s/\D+//g;

            # Sort numeric if possible, otherwise string
            int($an) <=> int($bn) || $a->{job_id} cmp $b->{job_id}
        } @$bad;
        $self->paint("\n");
        $exit += @$bad;
    }

    if ($fail) {
        my $sig = $self->{+SIGNAL};

        $self->paint("\n");

        $self->paint("Test runner exited badly: $exit\n") if $exit;
        $self->paint("Test runner exited badly: ?\n") unless defined $exit;
        $self->paint("An exception was caught\n") if !$ok && !$sig;
        $self->paint("Received SIG$sig\n") if $sig;
        $self->paint("$lost test files were never run!\n") if $lost;

        $self->paint("\n");

        $exit ||= 255;
    }

    if (!@$bad && !$fail) {
        $self->paint("\nAll tests were successful!\n\n");

        if ($settings->{cover}) {
            require IPC::Cmd;
            if(my $cover = IPC::Cmd::can_run('cover')) {
                system($^X, (map { "-I$_" } @INC), $cover);
            }
            else {
                $self->paint("You will need to run the `cover` command manually to build the coverage report.\n\n");
            }
        }
    }

    print "Keeping work dir: $settings->{dir}\n" if $settings->{keep_dir} && $settings->{dir};

    print "Wrote " . ($ok ? '' : '(Potentially Corrupt) ') . "log file: $settings->{log_file}\n"
        if $settings->{log};

    $exit = 255 unless defined $exit;
    $exit = 255 if $exit > 255;

    return $exit;
}
