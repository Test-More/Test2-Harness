package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001071';

use Test2::Harness::Util::TestFile;
use Test2::Harness::Feeder::Run;
use Test2::Harness::Run::Runner;
use Test2::Harness::Run::Queue;
use Test2::Harness::Run;

use Test2::Harness::Util::JSON qw/encode_json/;
use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;

use Test2::Harness::Util qw/parse_exit/;
use App::Yath::Util qw/is_generated_test_pl find_yath/;

use Time::HiRes qw/time/;
use Sys::Hostname qw/hostname/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub MAX_ATTACH() { 1_048_576 }

sub group { ' test' }

sub has_jobs      { 1 }
sub has_runner    { 1 }
sub has_logger    { 1 }
sub has_display   { 1 }
sub manage_runner { 1 }

sub summary { "Run tests" }
sub cli_args { "[--] [test files/dirs] [::] [arguments to test scripts]" }

sub description {
    return <<"    EOT";
This yath command (which is also the default command) will run all the test
files for the current project. If no test files are specified this command will
look for the 't', and 't2' dirctories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for
you by default.

Any command line argument that is not an option will be treated as a test file
or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This
is mainly useful for Test::Class::Moose and similar tools. EVERY test run will
get the same ARGV.
    EOT
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

sub normalize_settings {
    my $self = shift;

    $self->SUPER::normalize_settings();

    my $settings = $self->{+SETTINGS};

    # Make sure -v overrides --qvf
    $settings->{formatter} = '+Test2::Formatter::Test2'
        if $settings->{verbose} && $settings->{formatter} eq '+Test2::Formatter::QVF';

    unless ($settings->{slack_url}) {
        die "\n--slack-url is required when using --slack.\n"      if $settings->{slack};
        die "\n--slack-url is required when using --slack-fail.\n" if $settings->{slack_fail};
    }
}

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

        {
            spec => 'slack-url=s',
            field => 'slack_url',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--slack-url "URL"'],
            summary => ["Specify an API endpoint for slack webhook integrations"],
            long_desc => "This should be your slack webhook url.",
            action => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                eval { require HTTP::Tiny; 1 } or die "Cannot use --slack-url without HTTP::Tiny: $@";
                die "HTTP::Tiny reports that it does not support SSL, cannot use --slack-url without ssl."
                    unless HTTP::Tiny::can_ssl();
                $settings->{slack_url} = $arg;
            },
        },

        {
            spec => 'slack=s@',
            field => 'slack',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--slack "#CHANNEL"', '--slack "@USER"'],
            summary => ['Send results to a slack channel', 'Send results to a slack user'],
        },

        {
            spec => 'slack-fail=s@',
            field => 'slack_fail',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--slack-fail "#CHANNEL"', '--slack-fail "@USER"'],
            summary => ['Send failing results to a slack channel', 'Send failing results to a slack user'],
        },

        {
            spec => 'slack-notify!',
            field => 'slack_notify',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--slack-notify', '--no-slack-notify'],
            summary => ['On by default if --slack-url is specified'],
            long_desc => "Send slack notifications to the slack channels/users listed in test meta-data when tests fail.",
            default => 1,
        },

        {
            spec => 'slack-log!',
            field => 'slack_log',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--slack-log', '--no-slack-log'],
            summary => ['Off by default, log file will be attached if available'],
            long_desc => "Attach the event log to any slack notifications.",
            default => 0,
        },

        {
            spec => 'email-from=s@',
            field => 'email_from',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--email-from foo@example.com'],
            long_desc => "If any email is sent, this is who it will be from",
            default => sub {
                my $user = getlogin() || scalar(getpwuid($<)) || $ENV{USER} || 'unknown';
                my $host = hostname() || 'unknown';
                return "${user}\@${host}";
            },
        },

        {
            spec => 'email=s@',
            field => 'email',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--email foo@example.com'],
            long_desc => "Email the test results (and any log file) to the specified email address(es)",
            action => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                eval { require Email::Stuffer; 1 } or die "Cannot use --email without Email::Stuffer: $@";
                push @{$settings->{email}} => $arg;
            },
        },

        {
            spec => 'email-owner',
            field => 'email_owner',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--email-owner'],
            long_desc => 'Email the owner of broken tests files upon failure. Add `# HARNESS-META-OWNER foo@example.com` to the top of a test file to give it an owner',
            action => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                eval { require Email::Stuffer; 1 } or die "Cannot use --email-owner without Email::Stuffer: $@";
                $settings->{email_owner} = 1;
            },
        },

        {
            spec => 'batch-owner-notices!',
            field => 'batch_owner_notices',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--no-batch-owner-notices'],
            long_desc => 'Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.',
            default => 1,
        },

        {
            spec => 'notify-text=s',
            field => 'notify_text',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage => ['--notify-text "custom notification info"'],
            long_desc => "Add a custom text snippet to email/slack notifications",
        },

        {
            spec => 'qvf!',
            field => 'formatter',
            used_by => {display => 1},
            section   => 'Display Options',
            usage     => ['--qvf'],
            summary   => ['Quiet, but verbose on failure'],
            long_desc => 'Hide all output from tests when they pass, except to say they passed. If a test fails then ALL output from the test is verbosely output.',
            action   => sub {
                my ($self, $settings, $field, $arg) = @_;
                if ($arg) {
                    $settings->{formatter} = '+Test2::Formatter::QVF';
                }
                elsif ($settings->{formatter} eq '+Test2::Formatter::QVF') {
                    delete $settings->{formatter};
                }
            },
        },

        {
            spec    => 'uuids!',
            field   => 'event_uuids',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage   => ['--no-uuids'],
            summary => ['Disable Test2::Plugin::UUID (Loaded by default)'],
            default => 1,
        },

        {
            spec    => 'mem-usage!',
            field   => 'mem_usage',
            used_by => {jobs => 1},
            section => 'Job Options',
            usage   => ['--no-mem-usage'],
            summary => ['Disable Test2::Plugin::MemUsage (Loaded by default)'],
            default => 1,
        },
    );
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

    my $job_count = 0;
    for my $tf ($run->find_files) {
        $job_count++;
        $queue->enqueue($tf->queue_item($job_count));
    }

    my $pid = $runner->spawn(jobs_todo => $job_count);

    $queue->end;

    my $feeder = Test2::Harness::Feeder::Run->new(
        run      => $run,
        runner   => $runner,
        dir      => $settings->{dir},
        keep_dir => $settings->{keep_dir},
    );

    return ($feeder, $runner, $pid, $job_count);
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

            $settings->{batch_owner_notices} ? () : (
                email_owner  => $settings->{email_owner},
                email_from   => $settings->{email_from},
                slack_url    => $settings->{slack_url},
                slack_fail   => $settings->{slack_fail},
                slack_notify => $settings->{slack_notify},
                slack_log    => $settings->{slack_log},
                notify_text  => $settings->{notify_text},
            ),
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

    # Let the loggers clean up.
    $_->finish for @$loggers;
    @$loggers = ();

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

    for my $plugin (@{$self->{+PLUGINS}}) {
        $plugin->post_run(command => $self, settings => $settings, stat => $stat);
    }

    if (@$bad) {
        $self->paint("\nThe following test jobs failed:\n");
        $self->paint("  [", $_->{job_id}, '] ' . $_->{job_name} . ': ', File::Spec->abs2rel($_->file), "\n") for sort {
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

        if ($exit) {
            my $e = parse_exit($exit);
            $self->paint("Test runner exited badly, signal: $e->{sig}, error: $e->{err}\n");
        }
        $self->paint("Test runner exited badly\n") unless defined $exit;
        $self->paint("An exception was caught\n") if !$ok && !$sig;
        $self->paint("Received SIG$sig\n") if $sig;
        $self->paint("$lost test file(s) were never run!\n") if $lost;

        $self->paint("\n");

        $exit ||= 255;
    }

    if ($settings->{batch_owner_notices} && ($fail || @$bad)) {
        my (%owners, %slacks);
        for my $filename (map { $_->file } @$bad) {
            my $file = Test2::Harness::Util::TestFile->new(file => $filename);
            my @owners = $file->meta('owner');
            my @slacks = $file->meta('slack');
            push @{$owners{$_}} => File::Spec->abs2rel($filename) for @owners;
            push @{$slacks{$_}} => File::Spec->abs2rel($filename) for @slacks;
        }

        $self->send_owner_email(\%owners) if $settings->{email_owner};

        if ($settings->{slack_url}) {
            $self->send_slack_fail($bad) if $settings->{slack_fail};
            $self->send_slack_notify(\%slacks) if $settings->{slack_notify};
        }
    }
    else {
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

    $self->send_email if $settings->{email};
    $self->send_slack if $settings->{slack} && $settings->{slack_url};

    print "Keeping work dir: $settings->{dir}\n" if $settings->{keep_dir} && $settings->{dir};

    print "Wrote " . ($ok ? '' : '(Potentially Corrupt) ') . "log file: $settings->{log_file}\n"
        if $settings->{log};

    $exit = 255 unless defined $exit;
    $exit = 255 if $exit > 255;

    return $exit;
}

sub send_slack {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    require HTTP::Tiny;
    my $ht = HTTP::Tiny->new();

    my $text = "Test run $settings->{run_id} has completed on " . hostname();
    if (my $append = $settings->{notify_text}) {
        $text .= "\n$append";
    }

    for my $dest (@{$settings->{slack}}) {
        my $r = $ht->post(
            $settings->{slack_url},
            {
                headers => {'content-type' => 'application/json'},
                content => encode_json(
                    {
                        channel     => $dest,
                        text        => $text,
                        attachments => [
                            {
                                fallback => 'Test Summary',
                                pretext  => 'Test Summary',
                                text     => join('' => @{$self->{+PAINTED}}),
                            },
                        ],
                    }
                ),
            },
        );
        warn "Failed to send slack message to '$dest'" unless $r->{success};
    }
}

sub send_slack_fail {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    require HTTP::Tiny;
    my $ht = HTTP::Tiny->new();

    my $text = "Test run $settings->{run_id} failed on " . hostname();
    if (my $append = $settings->{notify_text}) {
        $text .= "\n$append";
    }

    for my $dest (@{$settings->{slack_fail}}) {
        my $r = $ht->post(
            $settings->{slack_url},
            {
                headers => {'content-type' => 'application/json'},
                content => encode_json(
                    {
                        channel     => $dest,
                        text        => $text,
                        attachments => [
                            {
                                fallback => 'Test Failure Summary',
                                pretext  => 'Test Failure Summary',
                                text     => join('' => @{$self->{+PAINTED}}),
                            },
                        ],
                    }
                ),
            },
        );
        warn "Failed to send slack message to '$dest'" unless $r->{success};
    }
}

sub send_slack_notify {
    my $self = shift;
    my ($slacks) = @_;

    my $settings = $self->{+SETTINGS};
    require HTTP::Tiny;
    my $ht   = HTTP::Tiny->new();
    my $host = hostname();

    my $text = "Test(s) failed on $host.";
    if (my $append = $settings->{notify_text}) {
        $text .= "\n$append";
    }

    for my $dest (sort keys %$slacks) {
        my $fails = join "\n" => @{$slacks->{$dest}};

        my $r = $ht->post(
            $settings->{slack_url},
            {
                headers => {'content-type' => 'application/json'},
                content => encode_json(
                    {
                        channel     => $dest,
                        text        => $text,
                        attachments => [
                            {
                                fallback => 'Test Failure Notifications',
                                pretext  => 'Test Failure Notifications',
                                text     => $fails,
                            },
                        ],
                    }
                ),
            },
        );
        warn "Failed to send slack message to '$dest'" unless $r->{success};
    }
}

sub send_email {
    my $self = shift;
    my $body = join '' => @{$self->{+PAINTED}};
    my $settings = $self->{+SETTINGS};
    $self->_send_email($body, @{$settings->{email}});
}

sub send_owner_email {
    my $self = shift;
    my ($owners) = @_;

    my $host  = hostname();
    for my $owner (sort keys %$owners) {
        my $fails = join "\n" => map { "  $_" } @{$owners->{$owner}};
        my $body  = <<"        EOT";
The following test(s) failed on $host. You are receiving this email because you
are listed as an owner of these tests.

Failing tests:
$fails
        EOT

        $self->_send_email($body, $owner);
    }
}

sub _send_email {
    my $self = shift;
    my ($body, @to) = @_;

    my $settings = $self->{+SETTINGS};
    my $host     = hostname();
    my $subject  = "Test run $settings->{run_id} on $host";

    $body = "$settings->{notify_text}\n\n$body" if $settings->{notify_text};

    $body .= "\nThe log file can be found on $host at " . File::Spec->rel2abs($settings->{log_file}) . "\n"
        if $settings->{log};

    my $mail = Email::Stuffer->to(@to);
    $mail->from($settings->{email_from});
    $mail->subject($subject);
    $mail->text_body($body);
    $mail->attach_file($settings->{log_file}) if $settings->{log} && (-s $settings->{log_file} <= MAX_ATTACH);
    eval { $mail->send_or_die; 1 } or warn $@;
}

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::test - Command to run tests

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

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
