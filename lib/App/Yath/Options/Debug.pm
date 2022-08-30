package App::Yath::Options::Debug;
use strict;
use warnings;

our $VERSION = '1.000127';

use Test2::Harness::Util::JSON qw/encode_pretty_json/;
use Test2::Util::Table qw/table/;
use Test2::Harness::Util qw/find_libraries mod2file clean_path/;

use Errno qw/EINTR/;

use App::Yath::Options;

option_group {prefix => 'debug', category => 'Help and Debugging'} => sub {
    post 99999 => \&_post_process_show_opts;
    post 99998 => \&_post_process_interactive;
    post \&_post_process_version;
    post \&_post_process_help;

    option dummy => (
        short          => 'd',
        description    => 'Dummy run, do not actually execute anything',
        env_vars       => [qw/T2_HARNESS_DUMMY/],
        clear_env_vars => 1,
        default        => 0,
    );

    option procname_prefix => (
        type => 's',
        default => '',
        description => 'Add a prefix to all proc names (as seen by ps).',
    );

    option keep_dirs => (
        short       => 'k',
        alt         => ['keep_dir'],
        description => 'Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.',
        default     => 0,
    );

    option 'show-opts' => (
        description => 'Exit after showing what yath thinks your options mean',
        pre_command => 1,
    );

    option version => (
        short       => 'V',
        description => "Exit after showing a helpful usage message",
        pre_command => 1,
    );

    option help => (
        short       => 'h',
        description => "exit after showing help information",
    );

    option interactive => (
        short => 'i',
        description => 'Use interactive mode, 1 test at a time, stdin forwarded to it',
    );

    option summary => (
        type        => 'd',
        description => "Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.",

        long_examples => ['', '=/path/to/summary.json'],

        normalize  => \&normalize_summary,
        action     => \&summary_action,
        applicable => sub {
            my ($option, $options) = @_;

            return 1 if $options->included->{'App::Yath::Options::Run'};
            return 0;
        },
    );
};

sub normalize_summary {
    my $val = shift;

    return $val if $val eq '1';

    $val =~ s/\.json$//g;
    $val .= '.json';

    return clean_path($val);
}

sub summary_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

    return $$slot = clean_path($norm)
        unless $norm eq '1';

    return if $$slot;
    return $$slot = clean_path('summary.json');
}

sub _post_process_help {
    my %params = @_;

    return unless $params{settings}->debug->help;

    my $help;
    if (my $cmd = $params{command}) {
        $help = $cmd->cli_help(%params);
    }
    else {
        $help = __PACKAGE__->cli_help(%params);
    }

    if (eval { require IO::Pager; 1 }) {
        local $SIG{PIPE} = sub {};
        my $pager = IO::Pager->new(*STDOUT);
        $pager->print($help);
    }
    else {
        print $help;
    }

    exit 0;
}

sub _post_process_show_opts {
    my %params = @_;

    return unless $params{settings}->debug->show_opts;

    my $settings = $params{settings};

    print "\nCommand selected: " . $params{command}->name . "  (" . ref($params{command}) . ")\n" if $params{command};

    my $args = $params{args};
    print "\nCommand args: " . join(', ' => @$args) . "\n" if @$args;

    my $out = encode_pretty_json($settings);

    print "\nCurrent command line and config options result in these settings:\n";
    print "$out\n";

    exit 0;
}

my $RAN = 0;
sub _post_process_interactive {
    return if $RAN++;
    my %params = @_;

    return unless $params{settings}->debug->interactive;

    my $settings = $params{settings};

    my ($fifo);
    if ($settings->check_prefix('workspace')) {
        my $dir = $settings->workspace->workdir;
        $fifo = "$dir/fifo-$$";
    }
    else {
        require File::Temp;
        my $fh;
        ($fh, $fifo) = File::Temp::tempfile("YATH-FIFO-$$-XXXXXX", TMPDIR => 1);
        close($fh);
        unlink($fifo);
    }

    ${$settings->debug->vivify_field('fifo')} = $fifo;

    if ($settings->check_prefix('display')) {
        $settings->display->field(quiet => 0);
        $settings->display->field(verbose => 1) unless $settings->display->verbose;
    }

    if ($settings->check_prefix('formatter')) {
        $settings->formatter->field(qvf => 0);
    }

    if ($settings->check_prefix('run')) {
        $settings->run->env_vars->{YATH_INTERACTIVE} = $fifo;
        $ENV{YATH_INTERACTIVE} = $fifo;
    }

    my $pid = fork() // die "Could not fork: $!";
    if ($pid) {
        require Time::HiRes;
        require POSIX;
        POSIX::mkfifo($fifo, 0700) or die "Failed to make fifo ($fifo): $!";

        my $fh;
        for (1 .. 10) {
            last if open($fh, '>', $fifo);
            die "Could not open fifo ($fifo): $!" unless $! == EINTR;
            sleep 1;
        }
        die "Could not open fifo ($fifo): $!" unless $fh;

        my $cleanup      = sub { close($fh); unlink($fifo) if -e $fifo };
        my $int_handler  = $SIG{INT};
        my $term_handler = $SIG{TERM};
        $SIG{INT}  = sub { $cleanup->(); $int_handler->()  if ref $int_handler;  exit 0; };
        $SIG{TERM} = sub { $cleanup->(); $term_handler->() if ref $term_handler; exit 0; };

        $fh->autoflush(1);

        STDIN->blocking(0);

        require Scope::Guard;
        my $guard = Scope::Guard->new($cleanup);

        while(1) {
            $SIG{PIPE} = sub { exit 0 };
            exit 0 if waitpid($pid, &POSIX::WNOHANG);
            exit 0 unless kill(0, $pid);
            my $data = <STDIN>;
            if (defined($data) && length($data)) {
                print $fh $data;
            }
            else {
                Time::HiRes::sleep(0.05);
            }
        }
    }

    close(STDIN);
    open(STDIN, '<', '/dev/null');

    require Time::HiRes;
    while (! -e $fifo) { Time::HiRes::sleep(0.1) };
}

sub _post_process_version {
    my %params = @_;

    return unless $params{settings}->debug->version;

    require App::Yath;
    my $out = <<"    EOT";

Yath version: $App::Yath::VERSION

Extended Version Info
    EOT

    my $plugin_libs = find_libraries('App::Yath::Plugin::*');

    my @vers = (
        [perl        => $^V],
        ['App::Yath' => App::Yath->VERSION],
        (
            map {
                eval { require(mod2file($_)); 1 }
                    ? [$_ => $_->VERSION // 'N/A']
                    : [$_ => 'N/A']
            } qw/Test2::API Test2::Suite Test::Builder/
        ),
        (
            map {
                eval { require($plugin_libs->{$_}); 1 }
                    && [$_ => $_->VERSION // 'N/A']
            } sort keys %$plugin_libs
        ),
    );

    $out .= join "\n" => table(
        header => [qw/COMPONENT VERSION/],
        rows   => \@vers,
    );

    print "$out\n\n";

    exit 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Debug - Debug options for Yath

=head1 DESCRIPTION

This is where debug related command line options live.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
