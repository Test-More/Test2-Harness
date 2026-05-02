package App::Yath2::Options::Workspace;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Spec();

use Test2::Harness2::Util qw/clean_path/;
use File::Path qw/remove_tree/;

use Getopt::Yath;

sub _workdir_default {
    return sub {
        my (undef, $settings) = @_;

        my $uuid = $settings->yath->instance_uuid
            or die "instance_uuid not set in settings; " . "App::Yath::Script::V2::do_begin() must run first";

        my $sys_tmp = File::Spec->tmpdir();
        my $workdir = File::Spec->catdir($sys_tmp, "yath-$uuid");

        unless (-d $workdir) {
            mkdir($workdir) or die "Could not create workdir '$workdir': $!";
        }

        return $workdir;
    };
}

option_group {group => 'workspace', category => 'Workspace Options'} => sub {
    option keep_dirs => (
        type        => 'Bool',
        short       => 'k',
        alt         => ['keep-dir'],
        description => 'Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.',
        default     => 0,
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

            # chmod_tmp($workdir); # TODO: port chmod_tmp from 2.0_borked2 / old/

            return;
        },

        default => _workdir_default(),
    );

    option tmpdir => (
        type           => 'Scalar',
        alt            => ['tmp-dir'],
        description    => 'Use a specific temp directory (Default: create a temp dir under the system one)',
        from_env_vars  => [qw/T2_HARNESS_TEMP_DIR YATH_TEMP_DIR/],
        clear_env_vars => [qw/T2_HARNESS_TEMP_DIR YATH_TEMP_DIR/],
        set_env_vars   => [qw/TMPDIR TEMPDIR TMP_DIR TEMP_DIR/],

        default => sub {
            my $opt = shift;
            my ($settings) = @_;

            my $dir = File::Spec->catdir($settings->workspace->workdir, 'tmp');

            unless (-d $dir) {
                mkdir($dir) or die "Could not mkdir($dir): $!";
            }

            # chmod_tmp($dir); # TODO: port chmod_tmp
            return $dir;
        },
    );

    option clear => (
        type        => 'Bool',
        short       => 'C',
        description => 'Clear the work directory if it is not already empty',
    );
};

option_post_process sub {
    my ($options, $state) = @_;

    my $settings = $state->{settings};

    remove_tree($settings->workspace->workdir, {safe => 1, keep_root => 1}) if $settings->workspace->clear;
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Workspace - FIXME

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

