package Test2::Harness::Job::Runner::Open3;
use strict;
use warnings;

our $VERSION = '0.001007';

use IPC::Open3 qw/open3/;
use Test2::Harness::Util qw/open_file write_file/;
use Test2::Util qw/pkg_to_file/;

use File::Spec();

sub viable { 1 }

sub find_inc {
    my $class = shift;

    # Find out where Test2::Harness::Run::Worker came from, make sure that is in our workers @INC
    my $inc = $INC{"Test2/Harness/Job/Runner.pm"};
    $inc =~ s{/Test2/Harness/Job/Runner\.pm$}{}g;
    return File::Spec->rel2abs($inc);
}

sub find_tcm_script {
    my $self = shift;

    my $script = $ENV{T2_HARNESS_TCM_SCRIPT} || 'yath-tcm';
    return $script if -f $script;

    if ($0 && $0 =~ m{(.*)\byath(-.*)?$}) {
        return "$1$script" if -f "$1$script";
    }

    # Do we have the full path?
    # Load IPC::Cmd only if needed, it indirectly loads version.pm which really
    # screws things up...
    require IPC::Cmd;
    if(my $out = IPC::Cmd::can_run($script)) {
        return $out;
    }

    die "Could not find '$script' in execution path";
}


sub run {
    my $class = shift;
    my ($test) = @_;

    my $job = $test->job;

    my ($in_file, $out_file, $err_file, $event_file) = $test->output_filenames;

    my $out_fh = open_file($out_file, '>');
    my $err_fh = open_file($err_file, '>');

    write_file($in_file, $job->input);
    my $in_fh = open_file($in_file, '<');

    my $env = {
        %{$job->env_vars},
        $job->use_stream ? (T2_FORMATTER => 'Stream') : (),
    };

    my @cmd = (
        $^X,
        (map { "-I$_" } @{$job->libs}, $class->find_inc),
        $ENV{HARNESS_PERL_SWITCHES} ? $ENV{HARNESS_PERL_SWITCHES} : (),
        @{$job->switches},
        (map {"-m$_"} @{$job->load || []}),
        (map {"-M$_"} @{$job->load_import || []}),
        $job->use_stream ? ("-MTest2::Formatter::Stream=file,$event_file") : (),
        $job->times ? ('-MTest2::Plugin::Times') : (),
        $job->tcm ? ($class->find_tcm_script) : (),
        $job->file,
        @{$job->args},
    );

    my $old;
    for my $key (keys %$env) {
        $old->{$key} = $ENV{$key} if exists $ENV{$key};
        $ENV{$key} = $env->{$key};
    }

    my $pid;

    my $ok = eval {
        $pid = open3(
            '<&' . fileno($in_fh), ">&" . fileno($out_fh), ">&" . fileno($err_fh),
            @cmd,
        );
        1;
    };
    my $err = $@;

    for my $key (keys %$env) {
        exists $old->{$key} ? $ENV{$key} = $old->{$key} : delete $ENV{$key};
    }

    die $@ unless $ok;

    return ($pid, undef);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::Runner::Open3 - Logic for running a test in a new perl
process.

=head1 DESCRIPTION

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
