use Test2::V0;

__END__

package App::Yath::Options::Workspace;
use strict;
use warnings;

our $VERSION = '0.001100';

use File::Spec();
use File::Temp qw/tempdir/;

use Test2::Harness::Util qw/clean_path/;

use App::Yath::Options;

option_group {prefix => 'workspace', category => "Workspace Options"} => sub {
    option use_shm => (
        alt         => ['shm'],
        description => "Use shm for tempdir if possible (Default: off)",
        action      => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;

            my ($found) = first { -d $_ } map { File::Spec->canonpath($_) } '/dev/shm', '/run/shm';
            $settings->workspace->tmp_dir = $found if $found;

            $handler->($slot, $norm);
        },
    );

    option tmp_dir => (
        type        => 's',
        short       => 't',
        alt         => ['tmpdir'],
        description => 'Use a specific temp directory (Default: use system temp dir)',
        default     => sub { $ENV{TMPDIR} || $ENV{TEMPDIR} || File::Spec->tmpdir },
    );

    option workdir => (
        type         => 's',
        short        => 'w',
        description  => 'Set the work directory (Default: new temp directory)',
        normalize    => \&clean_path,
        post_process => sub {
            my %params   = @_;
            my $settings = $params{settings};

            return if $settings->workspace->workdir;

            return $settings->workspace->workdir = $ENV{T2_WORKDIR} if $ENV{T2_WORKDIR};

            $settings->workspace->workdir = tempdir(
                "yath-test-$$-XXXXXXXX",
                DIR => $settings->workspace->tmp_dir,
                CLEANUP => !($settings->debug->keep_dirs || $params{command}->always_keep_dir),
            );
        }
    );

    option clear => (
        short       => 'C',
        description => 'Clear the work directory if it is not already empty',
    );
};

1;
