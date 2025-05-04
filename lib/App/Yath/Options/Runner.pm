package App::Yath::Options::Runner;
use strict;
use warnings;

our $VERSION = '2.000007';

use Test2::Util qw/IS_WIN32/;

use Test2::Harness::Util qw/mod2file fqmod clean_path/;

use Getopt::Yath;

include_options(
    'App::Yath::Options::Tests',
);

option_group {group => 'runner', category => "Runner Options"} => sub {
    option preload_early => (
        type => 'Map',
        description => 'Preload a module when spawning perl to launch the preload stages, before any other preload.',
    );

    option preloads => (
        type  => 'List',
        alt   => ['preload'],
        short => 'P',

        description => 'Preload a module before running tests',
    );

    option preload_retry_delay => (
        type => 'Scalar',
        default => 5,
        description => "Time in seconds to wait before trying to load a preload/stage after a failed attempt",
    );

    option class => (
        name    => 'runner',
        field   => 'class',
        type    => 'Scalar',

        default => sub {
            my ($opt, $settings) = @_;

            return 'Test2::Harness::Runner' if IS_WIN32;
            return 'Test2::Harness::Runner::Preloading' if @{$settings->runner->preloads // []};
            return 'Test2::Harness::Runner';
        },

        mod_adds_options => 1,
        long_examples    => [' MyRunner', ' +Test2::Harness::Runner::MyRunner'],
        description      => 'Specify what Runner subclass to use. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness::Runner::XXX namespace is assumed.',

        normalize => sub { fqmod($_[0], 'Test2::Harness::Runner') },
    );

    option dump_depmap => (
        type        => 'Bool',
        default     => 0,
        description => "When using staged preload, dump the depmap for each stage as json files",
    );

    option reload_in_place => (
        type        => 'Bool',
        alt         => ['reload'],
        default     => 0,
        description => "Reload modules in-place when possible (Not recommended)",
    );

    option reloader => (
        type => 'Auto',

        autofill  => 'Test2::Harness::Reloader',
        normalize => sub { fqmod($_[0], 'Test2::Harness::Reloader') },

        description => "Use a reloader (default Test2::Harness::Reloader) to detect module changes, and reload stages as necessary.",
    );

    option restrict_reload => (
        type => 'AutoList',
        normalize => sub { clean_path($_[0]) },
        autofill => sub {
            my ($opt, $settings) = @_;

            require Test2::Harness::TestSettings;
            my $ts = Test2::Harness::TestSettings->new($settings->tests->all);

            return map { clean_path($_) } @{$ts->includes};
        },
    );
};

option_post_process \&runner_post_process;

sub runner_post_process {
    my ($options, $state) = @_;

    my $settings = $state->{settings};
    my $runner   = $settings->runner;
    my $tests    = $settings->tests;

    warn "WARNING: Combining preload and switches will render preloads useless...\n"
        if @{$runner->preloads // []} && @{$tests->switches // []};
};

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Runner - FIXME

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

