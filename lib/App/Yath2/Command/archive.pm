package App::Yath2::Command::archive;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Spec ();
use POSIX qw/strftime/;

use App::Yath2::LogArchive;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;
include_options('App::Yath2::Options::Yath');

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Archive a yath log directory into a single file" }
sub cli_args { "[--] logdir [archive_filename]" }

sub description {
    return <<"    EOT";
Archive a yath log directory into a single tar.zidx file.

Required first argument: path to the log directory.

Optional second argument: output archive filename. Defaults to
"<system_tmp>/\${project}-\${user}-<YYYYMMDD-HHMMSS>-<pid>.yath" --
the current working directory is never used unless you pass an
explicit path that points at it.

yath only produces tar.zidx archives. The on-disk shape is a tar
(ustar) with per-file zstd compression and a trailing index for
random-access reads.
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $args = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $logdir = shift @$args;
    die "logdir is required\n"                  unless defined $logdir && length $logdir;
    die "logdir '$logdir' is not a directory\n" unless -d $logdir;

    my $archive = shift @$args;
    unless (defined $archive && length $archive) {
        my $project = $self->{+SETTINGS}->yath->project // '__UNKNOWN__';
        my $user    = $self->{+SETTINGS}->yath->user
                   // $ENV{USER}
                   // 'unknown';
        my $stamp   = strftime('%Y%m%d-%H%M%S', localtime);
        $archive = File::Spec->catfile(
            File::Spec->tmpdir(),
            "${project}-${user}-${stamp}-$$.yath",
        );
    }

    die "extra arguments after archive filename\n" if @$args;

    print "Archiving '$logdir' as '$archive'\n";

    App::Yath2::LogArchive->open(dir => $logdir)->archive($archive);

    print "Wrote archive: $archive\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
