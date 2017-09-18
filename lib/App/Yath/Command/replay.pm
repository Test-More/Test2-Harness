package App::Yath::Command::replay;
use strict;
use warnings;

our $VERSION = '0.001016';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::Feeder::JSONL;
use Test2::Harness::Run;
use Test2::Harness;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub summary { "Replay a test run from an event log" }

sub group { ' test' }

sub has_runner  { 0 }
sub has_logger  { 0 }
sub has_display { 1 }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]" }

sub description {
    return <<"    EOT";
This yath command will re-run the harness against an event log produced by a
previous test run. The only required argument is the path to the log file,
which maybe compressed. Any extra arguments are assumed to be job id's. If you
list any jobs, only listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.
    EOT
}

sub handle_list_args {
    my $self = shift;
    my ($list) = @_;

    my $settings = $self->{+SETTINGS};

    my ($log, @jobs) = @$list;

    $settings->{log_file} = $log;
    $settings->{jobs} = { map { $_ => 1 } @jobs} if @jobs;
    $settings->{run_id} ||= 'replay';

    die "You must specify a log file.\n"
        unless $log;

    die "Invalid log file: '$log'"
        unless -f $log;
}

sub feeder {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $feeder = Test2::Harness::Feeder::JSONL->new(file => $settings->{log_file});

    return ($feeder);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::replay - Command to replay a test run from an event log.

=head1 DESCRIPTION

=head1 SYNOPSIS



=head1 COMMAND LINE USAGE

    $ yath replay [options] [--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]

=head2 Help

=over 4

=item --show-opts

Exit after showing what yath thinks your options mean

=item -h

=item --help

Exit after showing this help message

=back

=head2 Display Options

=over 4

=item --color

=item --no-color

Turn color on (Default: on)

Turn color off

=item --show-job-info

=item --no-show-job-info

Show the job configuration when a job starts

(Default: off, unless -vv)

=item --show-job-launch

=item --no-show-job-launch

Show output for the start of a job

(Default: off unless -v)

=item --show-run-info

=item --no-show-run-info

Show the run configuration when a run starts

(Default: off, unless -vv)

=item -q

=item --quiet

Be very quiet

=item -v

=item -vv

=item --verbose

Turn on verbose mode.

Specify multiple times to be more verbose.

=item --formatter Mod

=item --formatter +Mod

Specify the formatter to use

(Default: "Test2")

Only useful when the renderer is set to "Formatter". This specified the Test2::Formatter::XXX that will be used to render the test output.

=item --show-job-end

=item --no-show-job-end

Show output when a job ends

(Default: on)

This is only used when the renderer is set to "Formatter"

=item -r +Module

=item -r Postfix

=item --renderer ...

Specify an alternate renderer

(Default: "Formatter")

Use "+" to give a fully qualified module name. Without "+" "Test2::Harness::Renderer::" will be prepended to your argument.

=back

=head2 Plugins

=over 4

=item -pPlugin

=item -p+My::Plugin

=item --plugin Plugin

Load a plugin

can be specified multiple times

=back

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
