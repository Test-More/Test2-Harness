package App::Yath::Command::spawn;
use strict;
use warnings;

our $VERSION = '1.000105';

use App::Yath::Options;

use Time::HiRes qw/sleep time/;
use File::Temp qw/tempfile/;

use Test2::Harness::Util qw/parse_exit/;

use parent 'App::Yath::Command::run';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Launch a perl script from the preloaded environment" }
sub cli_args { "[--] path/to/script.pl [options and args]" }

sub description {
    return <<"    EOT";
This will launch the specified script from the preloaded yath process.

NOTE: environment variables are not automatically passed to the spawned
process. You must use -e or -E (see help) to specify what environment variables
you care about.
    EOT
}

option_group {prefix => 'spawn', category => 'spawn options'} => sub {
    option stage => (
        short => 's',
        type => 's',
        description => 'Specify the stage to be used for launching the script',
        long_examples => [ ' foo'],
        short_examples => [ ' foo'],
        default => 'default',
    );

    option copy_env => (
        short => 'e',
        type => 'm',
        description => "Specify environment variables to pass along with their current values, can also use a regex",
        long_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
        short_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
    );

    option env_var => (
        field          => 'env_vars',
        short          => 'E',
        type           => 'h',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables for the spawn',
    );
};

sub read_line {
    my ($fh, $timeout) = @_;

    $timeout //= 300;

    my $start = time;
    while (1) {
        if ($timeout < (time - $start)) {
            my @caller = caller;
            die "Timed out at $caller[1] line $caller[2].\n";
        }
        seek($fh, 0,1) if eof($fh);
        my $out = <$fh> // next;
        chomp($out);
        return $out;
    }
}

# This is here for subclasses
sub queue_spawn {
    my $self = shift;
    my ($args) = @_;

    $self->state->queue_spawn($args);
}

sub run_script { shift @ARGV // die "No script specified" }

sub stage { $_[0]->settings->spawn->stage }

sub env_vars {
    my $self = shift;

    my $settings = $self->settings;

    my $env = {};

    for my $var (@{$settings->spawn->copy_env}) {
        if ($var =~ m{^/(.*)/(\w*)$}s) {
            my ($re, $opts) = ($1, $2);
            my $pattern = length($opts) ? "(?$opts)$re" : $re;
            $env->{$_} = $ENV{$_} for grep { m/$pattern/ } keys %ENV;
        }
        else {
            $env->{$var} = $ENV{$var};
        }
    }

    my $set = $settings->spawn->env_vars;
    $env->{$_} = $set->{$_} for keys %$set;

    return $env;
}

sub set_pname {
    my $self = shift;
    my ($run) = @_;

    $0 = "yath-" . $self->name . " $run " . join (' ', @ARGV);
}

sub pre_process_argv {
    shift @ARGV if @ARGV && $ARGV[0] eq '--';
}

sub sig_handlers { qw/INT TERM HUP QUIT USR1 USR2 STOP WINCH/ }

sub set_sig_handlers {
    my $self = shift;
    my ($wpid) = @_;

    local $@;
    eval { my $s = $_; $SIG{$s} = sub { kill($s, $wpid) } } for $self->sig_handlers;
}

sub clear_sig_handlers {
    my $self = shift;

    local $@;
    eval { my $s = $_; $SIG{$s} = 'DEFAULT' } for $self->sig_handlers;
}

sub pre_exit_hook {}

sub run {
    my $self = shift;

    $self->pre_process_argv;

    my $run = $self->run_script;
    $self->set_pname($run);

    my ($fh, $name) = tempfile(UNLINK => 1);
    close($fh);

    $self->queue_spawn({
        stage    => $self->stage // 'default',
        file     => $run,
        owner    => $$,
        ipcfile  => $name,
        args     => [@ARGV],
        env_vars => $self->env_vars,
    });

    open($fh, '<', $name) or die "Could not open ipcfile: $!";
    my $mpid = read_line($fh);
    my $wpid = read_line($fh);
    my $win  = read_line($fh);

    $self->set_sig_handlers($wpid);

    open(my $wfh, '>>', "/proc/$mpid/fd/$win") or die "Could not open /proc/$wpid/fd/$win: $!";
    $wfh->autoflush(1);
    STDIN->blocking(0);
    while (0 < kill(0, $mpid)) {
        my $line = <STDIN>;
        if (defined $line) {
            print $wfh $line;
        }
        else {
            sleep 0.2;
        }
    }

    $self->clear_sig_handlers();

    my $exit = read_line($fh) // die "Could not get exit code";
    $exit = parse_exit($exit);
    if ($exit->{sig}) {
        print STDERR "Terminated with signal: $exit->{sig}.\n";
        kill($exit->{sig}, $$);
    }

    print STDERR "Exited with code: $exit->{err}.\n" if $exit->{err};

    $self->pre_exit_hook($exit);

    exit($exit->{err});
}

1;

__END__

=head1 POD IS AUTO-GENERATED

