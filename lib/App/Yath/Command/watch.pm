package App::Yath::Command::watch;
use strict;
use warnings;

our $VERSION = '1.000048';

use Time::HiRes qw/sleep/;

use Test2::Harness::Util::File::JSON;

use App::Yath::Util qw/find_pfile/;
use Test2::Harness::Util qw/open_file/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Monitor the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will tail the logs from a persistent instance of yath. STDOUT and
STDERR will be printed as seen, so may not be in proper order.
    EOT
}

sub run {
    my $self = shift;

    my $args     = $self->args;
    shift @$args if @$args && $args->[0] eq '--';
    my $stop = 1 if @$args && $args->[0] eq 'STOP';

    my $pfile = find_pfile($self->settings)
        or die "No persistent harness was found for the current path.\n";

    print "\nFound: $pfile\n";
    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
    print "  PID: $data->{pid}\n";
    print "  Dir: $data->{dir}\n";
    print "\n";

    my $err_f = File::Spec->catfile($data->{dir}, 'error.log');
    my $out_f = File::Spec->catfile($data->{dir}, 'output.log');

    my $err_fh = open_file($err_f, '<');
    my $out_fh = open_file($out_f, '<');

    my $auxdir = File::Spec->catdir($data->{dir}, 'aux_logs');
    my %aux;

    while (1) {
        my $count = 0;
        while (my $line = <$out_fh>) {
            $count++;
            print STDOUT $line;
        }
        while (my $line = <$err_fh>) {
            $count++;
            print STDERR $line;
        }

        if (-d $auxdir) {
            opendir(my $dh, $auxdir) or die "Could not open auxdir: $!";
            for my $file (readdir($dh)) {
                next if $aux{$file};
                next unless $file =~ m/\.log$/;
                my $full = File::Spec->catfile($auxdir, $file);
                next unless -f $full;
                $aux{$file} = open_file($full, '<');
                $count++;
            }
        }

        for my $file (sort keys %aux) {
            my $fh = $aux{$file};
            my $ofh = $file =~ m/STDERR/ ? \*STDERR : \*STDOUT;
            while (my $line = <$fh>) {
                print $ofh $line;
            }
        }

        next if $count;
        last if $stop;
        last unless -f $pfile;
        sleep 0.02;
    }

    return 0;
}


1;

__END__

=head1 POD IS AUTO-GENERATED

