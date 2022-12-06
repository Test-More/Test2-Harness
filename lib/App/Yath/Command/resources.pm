package App::Yath::Command::resources;
use strict;
use warnings;

our $VERSION = '1.000139';

use Term::Table();
use File::Spec();
use Time::HiRes qw/sleep/;

use App::Yath::Util qw/find_pfile/;

use App::Yath::Options;
use Test2::Harness::Runner::State;
use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::Queue();

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/+state/;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Runner',
);

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
            return $self->{+STATE} = Test2::Harness::Runner::State->new(%$data, observe => 1);
        }

        if (my $pfile = find_pfile($self->settings, no_fatal => 1)) {
            my $data     = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
            my $workdir  = $data->{dir};
            my $settings = Test2::Harness::Util::File::JSON->new(name => "$workdir/settings.json")->read();

            return $self->{+STATE} = Test2::Harness::Runner::State->new(
                observe  => 1,
                job_count => $settings->{runner}->{job_count} // 1,
                workdir   => $data->{dir},
            );
        }
    }

    return;
}

sub shared {
    my $self = shift;

    my $shared;
    eval {
        require Test2::Harness::Runner::Resource::SharedJobSlots;
        $shared = Test2::Harness::Runner::Resource::SharedJobSlots->new(
            settings => $self->settings,
        );
        1;
    };

    return $shared;
}

sub run {
    my $self = shift;

    my $res;

    if(my $state = $self->state) {
        my @list;
        $res = sub {
            unless (@list) {
                $state->poll;
                @list = (@{$state->resources}, undef);
            }

            return shift @list;
        };
    }
    elsif (my $shared = $self->shared) {
        my $alt = 0;
        $res = sub {
            if ($alt) {
                $alt = 0;
                return undef;
            }

            $alt = 1;
            return $shared;
        };
    }

    die "No persistent runner, no running test, and no shared resources found\n"
        unless $res;

    while (1) {
        my @out = (
            "\r\e[2J\r\e[1;1H",
            "\n==== Resource state ====\n",
        );
        while (my $resource = $res->()) {
            my @lines = $resource->status_lines;
            next unless @lines;
            push @out => (
                "\nResource: " . ref($resource) . "\n",
                 join "\n" => @lines,
            );
        }
        push @out => "\n\n";
        print @out;
        sleep 0.1;
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

