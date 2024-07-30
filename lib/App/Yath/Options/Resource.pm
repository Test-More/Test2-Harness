package App::Yath::Options::Resource;
use strict;
use warnings;

our $VERSION = '2.000001';

use Test2::Harness::Util qw/mod2file fqmod/;

use Getopt::Yath;

option_group {group => 'resource', category => "Resource Options"} => sub {
    option classes => (
        type  => 'Map',
        short => 'R',
        name  => 'resources',
        field => 'classes',
        alt   => ['resource'],

        description => 'Specify resources. Use "+" to give a fully qualified module name. Without "+" "App::Yath::Resource::" and "Test2::Harness::Resource::" will be searched for a matching resource module.',

        long_examples  => [' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],
        short_examples => ['MyResource',     ' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],

        normalize => sub { fqmod($_[0], ['App::Yath::Resource', 'Test2::Harness::Resource']), ref($_[1]) ? $_[1] : [split(',', $_[1] // '')] },

        mod_adds_options => 1,
    );

    option slots => (
        type           => 'Scalar',
        short          => 'j',
        alt            => ['jobs', 'job-count'],
        description    => 'Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.',
        notes          => "If System::Info is installed, this will default to half the cpu core count, otherwise the default is 2.",
        long_examples  => [' 4', ' 8:2'],
        short_examples => ['4',  '8:2'],
        from_env_vars  => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],
        clear_env_vars => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],

        default => sub {
            my $ncore = eval { require System::Info; System::Info->new->ncore } || 0;
            if ($ncore) {
                if ($ncore > 2) {
                    $ncore /= 2;
                    print "System::Info is installed, setting job count to $ncore (Half the cores on this system)\n";
                    return $ncore;
                }
                else {
                    print "System::Info is installed, setting job count to 2 (Because we have less than 3 cores)\n";
                    return 2;
                }
            }

            print "Setting job count to 2. Install a sufficient version of System::Info to have this default to half the total number of cores.\n";
            return 2;
        },

        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            if ($params{action} eq 'set' || $params{action} eq 'initialize') {
                my ($val) = @{$params{val}};
                return unless $val && $val =~ m/:/;
                my ($jobs, $slots) = split /:/, $val;
                @{$params{val}} = ($jobs);
                $params{group}->{job_slots} = $slots;
            }
        },
    );

    option job_slots => (
        type  => 'Scalar',
        alt   => ['slots-per-job'],
        short => 'x',

        description    => "This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.",
        from_env_vars  => ['T2_HARNESS_JOB_CONCURRENCY'],
        clear_env_vars => ['T2_HARNESS_JOB_CONCURRENCY'],
        long_examples  => [' 2'],
        short_examples => ['2'],

        default => sub {
            my ($opt, $settings) = @_;
            $settings->resource->slots // 1;
        },
    );

    option_post_process 50 => \&jobs_post_process;
};

sub jobs_post_process {
    my ($options, $state) = @_;

    my $settings = $state->{settings};
    my $resource = $settings->resource;
    $resource->option(slots     => 1) unless $resource->slots;
    $resource->option(job_slots => 1) unless $resource->job_slots;

    my $slots     = $resource->slots;
    my $job_slots = $resource->job_slots;

    die "The slots per job (set to $job_slots) must not be larger than the total number of slots (set to $slots).\n" if $job_slots > $slots;

    $resource->option(classes => {}) unless $resource->classes;

    my %found;
    for my $r (keys %{$resource->classes}) {
        require(mod2file($r));
        next unless $r->is_job_limiter;
        $found{$r}++;
    }

    unless (keys %found) {
        require Test2::Harness::Resource::JobCount;
        $resource->classes->{'Test2::Harness::Resource::JobCount'} //= [];
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Resource - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

