package App::Yath;
use strict;
use warnings;

our $VERSION = '0.001008';

use App::Yath::Util qw/find_pfile/;

use Time::HiRes qw/time/;

our $SCRIPT;

sub import {
    my $class = shift;
    my ($argv, $runref) = @_;
    my ($pkg, $file, $line) = caller;

    $SCRIPT ||= $file;
    $ENV{YATH_SCRIPT} ||= $file;

    my $cmd_name  = $class->parse_argv($argv);
    my $cmd_class = $class->load_command($cmd_name);
    $cmd_class->import($argv);

    $$runref = sub { $class->run_command($cmd_class, $cmd_name, $argv) };
}

sub run_command {
    my $class = shift;
    my ($cmd_class, $cmd_name, $argv) = @_;

    my $cmd = $cmd_class->new(args => $argv);

    my $start = time;
    my $exit  = $cmd->run;

    die "Command '$cmd_name' did not return an exit value.\n"
        unless defined $exit;

    if ($cmd->show_bench) {
        require Test2::Util::Times;
        my $end = time;
        my $bench = Test2::Util::Times::render_bench($start, $end, times);
        print $bench, "\n\n";
    }

    return $exit;
}

sub parse_argv {
    my $class = shift;
    my ($argv) = @_;

    if (@$argv && $argv->[0] =~ m/^-*h(elp)?$/i) {
        shift @$argv;
        return 'help';
    }

    if (@$argv && -f $argv->[0] && $argv->[0] =~ m/\.jsonl(\.bz2|\.gz)$/) {
        print "\n** First argument is a log file, defaulting to the 'replay' command **\n\n";
        return 'replay';
    }

    if (!@$argv || -d $argv->[0] || -f $argv->[0] || substr($argv->[0], 0, 1) eq '-') {
        if (find_pfile) {
            print "\n** Persistent runner detected, defaulting to the 'run' command **\n\n";
            return 'run';
        }

        print "\n** Defaulting to the 'test' command **\n\n";
        return 'test';
    }

    return shift @$argv;
}

sub load_command {
    my $class = shift;
    my ($cmd_name) = @_;

    my $cmd_class  = "App::Yath::Command::$cmd_name";
    my $cmd_file   = "App/Yath/Command/$cmd_name.pm";

    if (!eval { require $cmd_file; 1 }) {
        my $load_error = $@ || 'unknown error';

        die "yath command '$cmd_name' not found. (did you forget to install $cmd_class?)\n"
            if $load_error =~ m{Can't locate \Q$cmd_file\E in \@INC};

        die $load_error;
    }

    return $cmd_class;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath - Yet Another Test Harness (Test2-Harness) Command Line Interface
(CLI)

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

=head1 DO NOT FORGET TO DOCUMENT

    # HARNESS-NO-PRELOAD
    # HARNESS-NO-STREAM
    # HARNESS-YES-TAP
    # HARNESS-USE-TAP
    # HARNESS-NO-TIMEOUT

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
