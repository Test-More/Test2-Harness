package App::Yath::Command::spawn;
use strict;
use warnings;

our $VERSION = '1.000029';

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
    EOT
}

option_group {prefix => 'spawn', category => 'spawn options'} => sub {
    option stage => (
        short => 's',
        type => 's',
        description => 'Specify the stage to be used for launching the script',
        default => 'default',
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

sub run {
    my $self = shift;
    my $state = $self->state;
    my $settings = $self->settings;

    shift @ARGV if @ARGV && $ARGV[0] eq '--';

    my $run = shift @ARGV // die "No script specified";
    my $stage = $settings->spawn->stage;

    my ($fh, $name) = tempfile(UNLINK => 1);
    close($fh);

    $state->queue_spawn({
        stage   => $stage,
        file    => $run,
        owner   => $$,
        ipcfile => $name,
        args    => [@ARGV],
    });

    $0 = "yath $run";

    open($fh, '<', $name) or die "Could not open ipcfile: $!";
    my $mpid = read_line($fh);
    my $wpid = read_line($fh);
    my $win  = read_line($fh);

    {
        local $@;
        eval { my $s = $_; $SIG{$s} = sub { kill($s, $wpid) } } for qw/INT TERM HUP QUIT USR1 USR2 STOP WINCH/;
    }

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

    {
        local $@;
        eval { my $s = $_; $SIG{$s} = 'DEFAULT' } for qw/INT TERM HUP QUIT USR1 USR2 STOP WINCH/;
    }

    my $exit = read_line($fh) // die "Could not get exit code";
    $exit = parse_exit($exit);
    if ($exit->{sig}) {
        print STDERR "Terminated with signal: $exit->{sig}.\n";
        kill($exit->{sig}, $$);
    }

    print STDERR "Exited with code: $exit->{err}.\n" if $exit->{err};
    exit($exit->{err});
}

1;

__END__

=head1 POD IS AUTO-GENERATED

