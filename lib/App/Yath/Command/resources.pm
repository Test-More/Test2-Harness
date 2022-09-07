package App::Yath::Command::resources;
use strict;
use warnings;

our $VERSION = '1.000134';

use Term::Table();
use File::Spec();
use Time::HiRes qw/sleep/;

use App::Yath::Util qw/find_pfile/;

use Test2::Harness::Runner::State;
use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::Queue();

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/+state/;

sub group { 'state' }

sub summary { "View the state info for a test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
A look at the state and resources used by a runner.
    EOT
}

sub pfile_params { (no_fatal => 1) }

sub newest {
    my ($a, $b) = @_;
    return $a unless $b;
    return $b unless $a;

    my @as = stat($a);
    my @bs = stat($b);
    return $a if $as[9] > $bs[9];
    return $b;
}

sub state {
    my $self = shift;

    return $self->{+STATE} if $self->{+STATE};

    my $info_file;
    opendir(my $dh, "./") or die "Could not open current dir: $!";
    for my $file (readdir($dh)) {
        next unless $file =~ m{^\.test_info\.\S+\.json$};
        $info_file = newest($info_file, "./$file");
    }

    my $pfile = find_pfile($self->settings, no_fatal => 1);

    if (my $use = newest($info_file, $pfile)) {
        if ($info_file) {
            my $data = Test2::Harness::Util::File::JSON->new(name => $info_file)->read;
            return $self->{+STATE} = Test2::Harness::Runner::State->new(%$data);
        }

        if (my $pfile = find_pfile($self->settings, no_fatal => 1)) {
            my $data     = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
            my $workdir  = $data->{dir};
            my $settings = Test2::Harness::Util::File::JSON->new(name => "$workdir/settings.json")->read();

            return $self->{+STATE} = Test2::Harness::Runner::State->new(
                job_count => $settings->{runner}->{job_count} // 1,
                workdir   => $data->{dir},
            );
        }
    }

    die "No persistent runner, and no running test found.\n";
}

sub run {
    my $self = shift;

    my $state = $self->state;

    while (1) {
        $state->poll;

        print "\r\e[2J\r\e[1;1H";
        print "\n==== Resource state ====\n";
        for my $resource (@{$state->resources}) {
            my @lines = $resource->status_lines;
            next unless @lines;
            print "\nResource: " . ref($resource) . "\n";
            print join "\n" => @lines;
        }
        print "\n\n";
        sleep 0.1;
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

