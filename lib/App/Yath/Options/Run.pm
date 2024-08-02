package App::Yath::Options::Run;
use strict;
use warnings;

our $VERSION = '2.000004';

use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util qw/fqmod/;
use List::Util qw/mesh/;

use Getopt::Yath;

include_options(
    'App::Yath::Options::Tests',
);

option_group {group => 'run', category => "Run Options"} => sub {
    option links => (
        alt  => ['link'],
        type => 'List',

        description => "Provide one or more links people can follow to see more about this run.",

        long_examples => [
            " 'https://travis.work/builds/42'",
            " 'https://jenkins.work/job/42'",
            " 'https://buildbot.work/builders/foo/builds/42'",
        ],
    );

    option dbi_profiling => (
        type    => 'Bool',
        default => 0,

        description => "Use Test2::Plugin::DBIProfile to collect database profiling data",

        trigger => sub {
            my $opt = shift;
            my %params = @_;

            return unless $params{action} eq 'set';

            eval { require Test2::Plugin::DBIProfile; 1 } or die "Could not enable DBI Profiling: $@";

            my $load_import = $params{settings}->tests->load_import;

            unless ($load_import->{'Test2::Plugin::DBIProfile'}) {
                $load_import->{'Test2::Plugin::DBIProfile'} //= [];
                push @{$load_import->{'@'}} => 'Test2::Plugin::DBIProfile';
            }
        },
    );

    option author_testing => (
        type  => "Bool",
        short => 'A',

        set_env_vars  => ['AUTHOR_TESTING'],
        from_env_vars => ['AUTHOR_TESTING'],
        description   => 'This will set the AUTHOR_TESTING environment to true',

        trigger => sub {
            my $opt = shift;
            my %params = @_;

            $params{settings}->tests->option(env_vars => {}) unless $params{settings}->tests->env_vars;

            if ($params{action} eq 'set') {
                $params{settings}->tests->env_vars->{AUTHOR_TESTING} = 1;
            }
            else {
                delete $params{settings}->tests->env_vars->{AUTHOR_TESTING};
            }
        },

    );

    option fields => (
        alt  => ['field'],
        type  => 'List',
        short => 'f',

        long_examples  => [' name=details', qq[ '{"name":"NAME","details":"DETAILS"}' ]],
        short_examples => [' name=details', qq[ '{"name":"NAME","details":"DETAILS"}' ]],
        description    => "Add custom data to the harness run",
        normalize      => sub { m/^\s*\{.*\}\s*$/s ? decode_json($_[0]) : {mesh(['name', 'details'], [split /[=]/, $_[0]])} },
    );

    option run_id => (
        type    => 'Scalar',
        alt     => ['id'],
        initialize => \&gen_uuid,

        description => 'Set a specific run-id. (Default: a UUID)',
    );

    option abort_on_bail => (
        type        => 'Bool',
        default     => 1,
        description => "Abort all testing if a bail-out is encountered (default: on)",
    );

    option nytprof => (
        type => 'Bool',
        description => "Use Devel::NYTProf on tests. This will set addpid=1 for you. This works with or without fork.",
        long_examples => [''],
    );

    option run_auditor => (
        type => 'Scalar',
        default => 'Test2::Harness::Collector::Auditor::Run',
        normalize => sub { fqmod($_[0], 'Test2::Harness::Collector::Auditor::Run') },
        description => 'Auditor class to use when auditing the overall test run',
    );

    option interactive => (
        type  => 'Bool',
        short => 'i',

        description   => 'Use interactive mode, 1 test at a time, stdin forwarded to it',
        set_env_vars  => ['YATH_INTERACTIVE'],
        from_env_vars => ['YATH_INTERACTIVE'],
    );
};

option_post_process 0 => sub {
    my ($options, $state) = @_;

    my $settings = $state->{settings};
    my $run   = $settings->run;

    return unless $run->interactive;

    if ($settings->check_group('renderer')) {
        my $r = $settings->renderer;
        $r->verbose(1) unless $r->verbose;
    }

    if ($settings->check_group('resource')) {
        my $r = $settings->resource;
        $r->job_slots(1);
        $r->slots(1);
    }
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Run - Run options for Yath.

=head1 DESCRIPTION

This is where command lines options for a single test run are defined.

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

