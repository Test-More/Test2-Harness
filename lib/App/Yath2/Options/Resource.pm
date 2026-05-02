package App::Yath2::Options::Resource;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Util qw/mod2file fqmod/;

use Getopt::Yath;

option_group {group => 'resource', category => "Resource Options"} => sub {
    option classes => (
        type  => 'Map',
        short => 'R',
        name  => 'resources',
        field => 'classes',
        alt   => ['resource'],

        description => 'Specify resources. Use "+" to give a fully qualified module name. Without "+" "App::Yath2::Resource::" and "Test2::Harness2::Resource::" will be searched for a matching resource module.',

        long_examples  => [' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],
        short_examples => ['MyResource',     ' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],

        normalize => sub { fqmod($_[0], ['App::Yath2::Resource', 'Test2::Harness2::Resource']), ref($_[1]) ? $_[1] : [split(',', $_[1] // '')] },

        mod_adds_options => 1,

        # --no-resource / --no-resources is the auto-generated clear
        # form. Record the clear so the post-process step below can
        # tell "user explicitly asked for no limiter" apart from "user
        # never specified one".
        trigger => sub {
            my $opt    = shift;
            my %params = @_;
            return unless $params{action} eq 'clear';
            $params{group}->{no_resource} = 1;
        },
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

        default => sub { 1 },
    );

    # The "no limiter at all, run with unlimited concurrency" opt-out
    # rides on the auto-generated --no-resource / --no-resources clear
    # form of the `classes` Map option above. Getopt::Yath registers
    # those automatically (every option gets a --no-X clear form, plus
    # one per `alt`). The `classes` option's trigger above records
    # whether a clear was requested in $group->{no_resource}; the
    # post-process step below honours that flag (and refuses to inject
    # the default JobCount).

    option utilize => (
        type           => 'Scalar',
        short          => 'U',
        description    => 'Percentage of system utilization (0 < pct < 100) at which any utilization-aware resources should signal temporarily-unavailable. Each resource that consumes the Test2::Harness2::Role::Resource::Utilizer role is given this percentage; once its monitored subsystem (CPU, memory, /tmp space, etc.) crosses the threshold the resource starts deferring new assignments. Pairs with a per-class spawn-throttle window (see POD).',
        long_examples  => [' 80', ' 50'],
        short_examples => [' 80', ' 50'],

        # The role implementations are not wired up yet; this option is
        # a stub that validates the input and propagates it through
        # settings so each resource can pick it up when the role
        # contract is implemented.
        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            return unless $params{action} eq 'set' || $params{action} eq 'initialize';

            my ($val) = @{$params{val}};
            return unless defined $val;

            die "--utilize must be a number\n"
                unless $val =~ m/^[0-9]+(?:\.[0-9]+)?\z/;

            die "--utilize must be greater than 0 and less than 100 (got '$val')\n"
                unless $val > 0 && $val < 100;
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

    # New rule (Phase 6.2): the harness no longer mandates a job
    # limiter; yath-test is the layer that injects the default.
    #
    # 1. If the user supplied any --resource / -R, do nothing -- the
    #    supplied set is authoritative.
    # 2. Otherwise, if --no-resource / --no-resources was set, also do
    #    nothing -- the user explicitly asked for a no-limiter harness.
    # 3. Otherwise inject Test2::Harness2::Resource::JobCount; the slot
    #    count comes from --slots (-j), which already has a
    #    System::Info-backed default that falls back to 2.
    return if keys %{$resource->classes};

    # `no_resource` is only present in the group hash when the
    # classes Map's clear-form trigger fired (--no-resource /
    # --no-resources). Use check_option so reading the absent key does
    # not croak.
    return if $resource->check_option('no_resource') && $resource->no_resource;

    require Test2::Harness2::Resource::JobCount;
    $resource->classes->{'Test2::Harness2::Resource::JobCount'} //= [];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Resource - Resource-related options for yath commands.

=head1 DESCRIPTION

Defines the C<--resource> / C<-R>, C<--slots> / C<-j>, C<--job-slots>
/ C<-x>, C<--no-resource>, and C<--utilize> / C<-U> options.

=head2 The --utilize / -U option (stub)

C<--utilize PCT> is a stub option (Phase 6.3 of the resource model
overhaul). It accepts a percentage strictly greater than C<0> and
strictly less than C<100>; values outside that range or non-numeric
values are rejected at option-parse time.

The intended (not-yet-wired) behavior: every resource class that
consumes L<Test2::Harness2::Role::Resource::Utilizer> receives the
percentage and uses it as its "this subsystem is too utilized; defer
new assignments" threshold. The exact subsystem (CPU load, free
memory, free C</tmp> space, etc.) is per-resource. The option exists
now so command-line plumbing, validation, and propagation are in
place; the role contract and per-resource implementations are wired
up in follow-on work.

=head3 Spawn-throttle pairing

The percentage gate alone is not sufficient: a freshly spawned test
needs a moment to actually consume CPU/memory/disk before the
resource sample reflects it. Without throttling the harness would
launch a burst of tests against an apparently-idle system and only
notice the over-commit on the next sample.

The Utilizer role pairs the percentage with a spawn-throttle window:

=over 4

=item *

In a sliding 2-second window, count the delta C<(spawned - exited)>.

=item *

If the delta is at or above a per-class threshold, wait one more
second before starting the next batch.

=item *

If 40 spawn and 40 exit in the same 2 seconds (delta C<0>), the
window is "balanced" and there is no throttling -- short tests are
allowed to roll through at full speed.

=back

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

