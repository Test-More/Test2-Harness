package App::Yath::Command::resources;
use strict;
use warnings;

our $VERSION = '1.000126';

use Carp::Always;
use Term::Table();
use File::Spec();

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

sub state {
    my $self = shift;

    return $self->{+STATE} if $self->{+STATE};

    if( my $pfile = find_pfile($self->settings, no_fatal => 1)) {
        my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
        my $workdir = $data->{dir};
        my $settings = Test2::Harness::Util::File::JSON->new(name => "$workdir/settings.json")->read();

        return $self->{+STATE} = Test2::Harness::Runner::State->new(
            job_count    => $settings->{runner}->{job_count} // 1,
            workdir      => $data->{dir},
        );
    }

    if (-e './.test_info.json') {
        my $data = Test2::Harness::Util::File::JSON->new(name => './.test_info.json')->read;
        return $self->{+STATE} = Test2::Harness::Runner::State->new(%$data);
    }

    die "No persistent runner, and no running test found.\n";
}

sub run {
    my $self = shift;

    my $state = $self->state;
    $state->poll;

    print "\n==== Resource state ====\n";
    for my $resource (@{$state->resources}) {
        my @lines = $resource->status_lines;
        next unless @lines;
        print "\nResource: " . ref($resource) . "\n";
        print join "\n" => @lines;
    }
    print "\n\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

