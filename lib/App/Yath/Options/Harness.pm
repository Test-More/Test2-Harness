package App::Yath::Options::Harness;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();
use Test2::Harness::Util qw/find_libraries mod2file clean_path chmod_tmp/;
use File::Temp qw/tempdir/;
use Getopt::Yath;

option_group {group => 'harness', category => 'Harness Options'} => sub {
    option dummy => (
        type           => 'Bool',
        short          => 'd',
        description    => 'Dummy run, do not actually execute anything',
        from_env_vars  => [qw/T2_HARNESS_DUMMY/],
        clear_env_vars => [qw/T2_HARNESS_DUMMY/],
        default        => 0,
    );

    warn "Prefix";
    option procname_prefix => (
        type        => 'Scalar',
        default     => '',
        description => 'Add a prefix to all proc names (as seen by ps).',
    );

    option keep_dirs => (
        type        => 'Bool',
        short       => 'k',
        alt         => ['keep_dir'],
        description => 'Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.',
        default     => 0,
    );

    option tmpdir => (
        type           => 'Scalar',
        alt            => ['tmp_dir'],
        description    => 'Use a specific temp directory (Default: use system temp dir)',
        from_env_vars  => [qw/T2_HARNESS_TEMP_DIR YATH_TEMP_DIR TMPDIR TEMPDIR TMP_DIR TEMP_DIR/],
        clear_env_vars => [qw/T2_HARNESS_TEMP_DIR YATH_TEMP_DIR/],
        default        => sub { File::Spec->tmpdir },
    );

    option workdir => (
        type           => 'Scalar',
        description    => 'Set the work directory (Default: new temp directory)',
        from_env_vars  => [qw/T2_WORKDIR YATH_WORKDIR/],
        clear_env_vars => [qw/T2_WORKDIR YATH_WORKDIR/],
        normalize      => \&clean_path,

        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            return unless $params{action} eq 'set';

            my $val = $params{val} or return;
            my ($workdir) = @$val;

            unless (-d $workdir) {
                mkdir($workdir) or die "Could not create workdir: $!";
            }

            chmod_tmp($workdir);

            return $workdir;
        },

        default => sub {
            my $opt = shift;
            my ($settings) = @_;

            my $template = join '-' => ("yath", $$, "XXXXXX");

            my $workdir = tempdir(
                $template,
                DIR     => $settings->harness->tmpdir,
                CLEANUP => 0,
            );

            chmod_tmp($workdir);

            return $workdir;
        },
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Harness - Options for any command that interacts with the harness API

=head1 DESCRIPTION

Options for any command that interacts with the harness API.

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

Copyright 2023 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
