package App::Yath2::Options::LogArchive;
use strict;
use warnings;

our $VERSION = '2.000011';

use Getopt::Yath;

option_group {group => 'log_archive', category => 'Log Archive Options'} => sub {
    option log => (
        type        => 'Bool',
        short       => 'L',
        default     => 0,
        description => 'Turn on user-visible log archiving. The archive is written by App::Yath2::LogArchive; --log-file or --log-dir choose the destination.',
    );

    option dir => (
        prefix      => 'log',
        type        => 'Scalar',
        description => 'Write the log archive into this directory using the ${project}-${user}-${stamp}-${pid}.yath naming convention. Ignored when --log-file is also set.',
    );

    option file => (
        prefix      => 'log',
        type        => 'Scalar',
        short       => 'F',
        description => 'Write the log archive to this exact path. Wins over --log-dir; the path is used verbatim, no extension is appended.',
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::LogArchive - User-facing log archive destination options
(--log / -L, --log-dir, --log-file / -F).

=head1 DESCRIPTION

Defines the C<log_archive> option group consumed by C<yath test> (and
any future command that wants the same destination semantics) to
choose where the run's log archive is written.

The actual archive write happens in the consuming command; this
module only owns the option parsing and the C<$settings-E<gt>log_archive>
accessor.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=cut
