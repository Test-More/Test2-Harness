package App::Yath::Options::Workspace;
use strict;
use warnings;

our $VERSION = '1.000120';

use File::Spec();
use File::Path qw/remove_tree/;
use File::Temp qw/tempdir/;

use Test2::Harness::Util qw/clean_path chmod_tmp/;

use App::Yath::Options;

option_group {prefix => 'workspace', category => "Workspace Options"} => sub {
    option tmp_dir => (
        type        => 's',
        short       => 't',
        alt         => ['tmpdir'],
        description => 'Use a specific temp directory (Default: use system temp dir)',
        env_vars => [qw/T2_HARNESS_TEMP_DIR YATH_TEMP_DIR TMPDIR TEMPDIR TMP_DIR TEMP_DIR/],
        default     => sub { File::Spec->tmpdir },
    );

    option workdir => (
        type         => 's',
        short        => 'w',
        description  => 'Set the work directory (Default: new temp directory)',
        env_vars => [qw/T2_WORKDIR YATH_WORKDIR/],
        clear_env_vars => 1,
        normalize    => \&clean_path,
    );

    option clear => (
        short       => 'C',
        description => 'Clear the work directory if it is not already empty',
    );

    post sub {
        my %params   = @_;
        my $settings = $params{settings};

        if (my $workdir = $settings->workspace->workdir) {
            if (-d $workdir) {
                remove_tree($workdir, {safe => 1, keep_root => 1}) if $settings->workspace->clear;
            }
            else {
                mkdir($workdir) or die "Could not create workdir: $!";
                chmod_tmp($workdir);
            }

            return;
        }

        my $project = $settings->harness->project;
        my $template = join '-' => ( "yath", $$, "XXXXXX");

        my $tmpdir = tempdir(
            $template,
            DIR     => $settings->workspace->tmp_dir,
            CLEANUP => !($settings->debug->keep_dirs || $params{command}->always_keep_dir),
        );
        chmod_tmp($tmpdir);

        $settings->workspace->field(workdir => $tmpdir);
    };
};

1;

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Workspace - Options for specifying the yath work dir.

=head1 DESCRIPTION

Options regarding the yath working directory.

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
