use Test2::V0;

__END__

package App::Yath::Options::Run;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::Harness::Util::UUID qw/gen_uuid/;

use App::Yath::Options;

option_group {prefix => 'run', category => "Run Options", builds => 'Test2::Harness::Run'} => sub {
    option test_args => (
        type => 'm',

        description => 'Arguments to pass in as @ARGV for all tests that are run. These can be provided easier using the \'::\' argument seperator.'
    );

    option search => (
        type => 'm',

        description => 'List of tests and test directories to use instead of the default search paths. Typically these can simply be listed as command line arguments without the --search prefix.',
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
                $settings->run->input = undef;
            }

            $handler->($slot, $norm);
        },
    );

    option author_testing => (
        short        => 'A',
        description  => 'This will set the AUTHOR_TESTING environment to true',
        post_process => \&author_testing_post_process,
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
        description => "The TAP format is lossy and clunky. Test2::Harness normally uses a newer streaming format to receive test results. There are old/legacy tests wh    ere this causes problems, in which case setting --TAP or --no-stream can help."
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

    option no_long => (
        description => "Do not run tests that have their duration flag set to 'LONG'",
    );

    option only_long => (
        description => "Only run tests that have their duration flag set to 'LONG'",
    );

    option durations => (
        type => 's',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option maybe_durations => (
        type => 's',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option exclude_file => (
        field => 'exclude_files',
        type  => 'm',

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a file from testing",
    );

    option exclude_pattern => (
        field => 'exclude_patterns',
        type  => 'm',

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a pattern from testing, matched using m/\$PATTERN/",
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
        short => 'H',
        alt   => ['loadim'],

        long_examples  => [' Module', ' Module=import_arg1,arg2,...'],
        short_examples => [' Module', ' Module=import_arg1,arg2,...'],

        description => 'Load a module in each test (after fork). Import is called.',
    );

    option default_search => (
        type => 'm',

        description => "Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line",

        post_process => sub {
            my %params = @_;
            my $settings = $params{settings};
            $settings->run->default_search = ['./t', './t2', 'test.pl']
                unless $settings->run->default_search && @{$settings->run->default_search};
        },
    );

    option default_at_search => (
        type => 'm',

        description => "Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line",

        post_process => sub {
            my %params = @_;
            my $settings = $params{settings};
            $settings->run->default_at_search = ['./xt']
                unless $settings->run->default_at_search && @{$settings->run->default_at_search};
        },
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
};

sub author_testing_post_process {
    my %params   = @_;
    my $settings = $params{settings};
    $settings->run->env_vars->{AUTHOR_TESTING} = 1 if $settings->run->author_testing;
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

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
