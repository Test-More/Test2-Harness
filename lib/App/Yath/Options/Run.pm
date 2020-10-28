package App::Yath::Options::Run;
use strict;
use warnings;

our $VERSION = '1.000034';

use Test2::Harness::Util::UUID qw/gen_uuid/;

use App::Yath::Options;

option_group {prefix => 'run', category => "Run Options", builds => 'Test2::Harness::Run'} => sub {
    post \&post_process;

    option link => (
        field => 'links',
        type => 'm',
        long_examples  => [
            " 'https://travis.work/builds/42'",
            " 'https://jenkins.work/job/42'",
            " 'https://buildbot.work/builders/foo/builds/42'",
        ],
        description => "Provide one or more links people can follow to see more about this run."
    );

    option test_args => (
        type => 'm',
        description => 'Arguments to pass in as @ARGV for all tests that are run. These can be provided easier using the \'::\' argument separator.'
    );

    option input => (
        type        => 's',
        description => 'Input string to be used as standard input for ALL tests. See also: --input-file',
    );

    option input_file => (
        type        => 's',
        description => 'Use the specified file as standard input to ALL tests',
        action      => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;

            die "Input file not found: $norm\n" unless -f $norm;
            if ($settings->run->input) {
                warn "Input file is overriding another source of input.\n";
                $settings->run->field(input => undef);
            }

            $handler->($slot, $norm);
        },
    );

    option dbi_profiling => (
        type => 'b',
        description => "Use Test2::Plugin::DBIProfile to collect database profiling data",
    );

    option cover_files => (
        type => 'b',
        description => "Use Test2::Plugin::Cover to collect coverage data for what files are touched by what tests. Unlike Devel::Cover this has very little performance impact (About 4% difference)",
    );

    option author_testing => (
        short        => 'A',
        description  => 'This will set the AUTHOR_TESTING environment to true',
    );

    option use_stream => (
        name        => 'stream',
        description => "Use the stream formatter (default is on)",
        default     => 1,
    );

    option tap => (
        field       => 'use_stream',
        alt         => ['TAP', '--no-stream'],
        normalize   => sub { $_[0] ? 0 : 1 },
        description => "The TAP format is lossy and clunky. Test2::Harness normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help."
    );

    option fields => (
        type           => 'm',
        short          => 'f',
        long_examples  => [' name:details', ' JSON_STRING'],
        short_examples => [' name:details', ' JSON_STRING'],
        description    => "Add custom data to the harness run",
        action         => \&fields_action,
    );

    option env_var => (
        field          => 'env_vars',
        short          => 'E',
        type           => 'h',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables to set when each test is run.',
    );

    option run_id => (
        alt         => ['id'],
        description => 'Set a specific run-id. (Default: a UUID)',
        default     => \&gen_uuid,
    );

    option load => (
        type        => 'm',
        short       => 'm',
        alt         => ['load-module'],
        description => 'Load a module in each test (after fork). The "import" method is not called.',
    );

    option load_import => (
        type  => 'H',
        short => 'M',
        alt   => ['loadim'],

        long_examples  => [' Module', ' Module=import_arg1,arg2,...'],
        short_examples => [' Module', ' Module=import_arg1,arg2,...'],

        description => 'Load a module in each test (after fork). Import is called.',
    );

    option event_uuids => (
        default => 1,
        alt => ['uuids'],
        description => 'Use Test2::Plugin::UUID inside tests (default: on)',
    );

    option mem_usage => (
        default => 1,
        description => 'Use Test2::Plugin::MemUsage inside tests (default: on)',
    );

    option io_events => (
        default => 0,
        description => 'Use Test2::Plugin::IOEvents inside tests to turn all prints into test2 events (default: off)',
    );

    option retry => (
        default => 0,
        short => 'r',
        type => 's',
        description => 'Run any jobs that failed a second time. NOTE: --retry=1 means failing tests will be attempted twice!',
    );

    option retry_isolated => (
        default => 0,
        alt => ['retry-iso'],
        type => 'b',
        description => 'If true then any job retries will be done in isolation (as though -j1 was set)',
    );
};

sub post_process {
    my %params   = @_;
    my $settings = $params{settings};

    $settings->run->env_vars->{AUTHOR_TESTING} = 1 if $settings->run->author_testing;

    if ($settings->run->cover_files) {
        eval { require Test2::Plugin::Cover; 1 } or die "Could not enable file coverage, could not load 'Test2::Plugin::Cover': $@";
        push @{$settings->run->load_import->{'@'}} => 'Test2::Plugin::Cover';
        $settings->run->load_import->{'Test2::Plugin::Cover'} = [];
    }

    if ($settings->run->dbi_profiling) {
        eval { require Test2::Plugin::DBIProfile; 1 } or die "Could not enable DBI profiling, could not load 'Test2::Plugin::DBIProfile': $@";
        push @{$settings->run->load_import->{'@'}} => 'Test2::Plugin::DBIProfile';
        $settings->run->load_import->{'Test2::Plugin::DBIProfile'} = [];
    }
}

sub fields_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

    my $fields = ${$slot} //= [];

    if ($norm =~ m/^{/) {
        my $field = {};
        my $ok    = eval { $field = Test2::Harness::Util::JSON::decode_json($norm); 1 };
        chomp(my $error = $@ // '');

        die "Error parsing field specification '$field': $error\n" unless $ok;
        die "Fields must have a 'name' key (error in '$raw')\n"    unless $field->{name};
        die "Fields must habe a 'details' key (error in '$raw')\n" unless $field->{details};

        return push @$fields => $field;
    }
    elsif ($norm =~ m/([^:]+):([^:]+)/) {
        return push @$fields => {name => $1, details => $2};
    }

    die "'$raw' is not a valid field specification.\n";
}

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
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
