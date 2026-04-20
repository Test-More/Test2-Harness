package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Temp ();
use File::Spec ();

use Object::HashBase qw{
    <script
    <config
    <user_config
};

# The test command's argv is stored as a string hash key because Perl
# reserves the bareword ARGV for the magic filehandle. See App::Yath2
# for the same workaround.
sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

sub run {
    my $self = shift;

    require App::Yath2::Finder::Simple;

    my $argv = $self->argv;

    unless (@$argv) {
        print STDERR "yath test: no tests given\n";
        print STDERR "Usage: yath test FILE [FILE...] | DIRECTORY [DIRECTORY...]\n";
        return 2;
    }

    my $ok = eval {
        _run_tests($argv);
    };
    if (!defined $ok) {
        my $err = $@;
        print STDERR "yath test: error: $err\n";
        return 2;
    }
    return $ok;
}

sub _run_tests {
    my ($paths) = @_;

    require Test2::Harness2;

    my @tests = App::Yath2::Finder::Simple->find(@$paths);
    unless (@tests) {
        print STDERR "yath test: no test files discovered under given paths\n";
        return 2;
    }

    my $dir = File::Temp->newdir('yath-test-XXXXXX', TMPDIR => 1);

    print STDOUT "yath test: running ", scalar(@tests), " test file(s) under $dir\n";

    my $spawn = Test2::Harness2->spawn(
        workdir                  => "$dir",
        test_run                 => {files => \@tests},
        finish_after_initial_run => 1,
    );

    # Wait for the service to finish of its own accord (finish_after sets
    # the flag so the run loop exits after the queue drains).
    # Spawn->wait calls waitpid(), which sets $?. Perl's exit() propagates
    # $? from END/DESTROY cleanup back to the parent, so the service's
    # own wait-status would silently clobber the exit code we compute
    # from the per-job verdicts. Localize $? across the wait to prevent
    # that leak.
    {
        local $?;
        $spawn->wait;
    }

    my $runs_dir = File::Spec->catdir("$dir", 'logs', 'runs');

    my ($pass, $fail) = _tally_results($runs_dir);

    print STDOUT "yath test: pass=$pass fail=$fail\n";

    return $fail ? 1 : 0;
}

# Walk $runs_dir looking for per-job 0.json sidecars and tally the
# pass/fail counts in their payloads. Every 0.json written by
# Collector::Logger::JSON records either {pass => 1} or {pass => 0}
# at shutdown; jobs whose collector died before writing a verdict are
# counted as failures.
sub _tally_results {
    my ($runs_dir) = @_;

    return (0, 1) unless -d $runs_dir;    # no runs written => treat as 1 fail

    require Test2::Harness2::Util::JSON;
    Test2::Harness2::Util::JSON->import(qw/decode_json/);

    my $pass = 0;
    my $fail = 0;

    opendir(my $dh, $runs_dir) or return (0, 1);
    my @run_ids = grep { !/^\./ } readdir($dh);
    closedir($dh);

    for my $run (@run_ids) {
        my $run_dir = File::Spec->catdir($runs_dir, $run);
        next unless -d $run_dir;

        opendir(my $jdh, $run_dir) or next;
        my @job_ids = grep { !/^\./ } readdir($jdh);
        closedir($jdh);

        for my $job (@job_ids) {
            my $job_dir = File::Spec->catdir($run_dir, $job);
            next unless -d $job_dir;

            my $sidecar = File::Spec->catfile($job_dir, '0.json');
            unless (-f $sidecar) {
                $fail++;
                next;
            }

            my $ok = eval {
                open(my $fh, '<', $sidecar) or die "open '$sidecar': $!";
                local $/;
                my $blob = <$fh>;
                close($fh);
                my $data = decode_json($blob);
                # The collector writes 'pass' only when an auditor is
                # attached. Missing/false 'pass' is a fail.
                if ($data->{pass}) {
                    $pass++;
                }
                else {
                    $fail++;
                }
                1;
            };
            unless ($ok) {
                warn "yath test: could not parse $sidecar: $@";
                $fail++;
            }
        }
    }

    return ($pass, $fail);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::test - Minimal 'yath test' command (Stage 5).

=head1 DESCRIPTION

Stage 5 implementation of the C<yath test> command. Accepts a list of
positional test-file / directory arguments, no options, and runs them
through a transient L<Test2::Harness2> service.

The command:

=over 4

=item * Uses L<App::Yath2::Finder::Simple> to expand directories into
        C<*.t> files.

=item * Creates a temporary workdir via L<File::Temp>.

=item * Calls C<< Test2::Harness2->spawn(...) >> with
        C<finish_after_initial_run =E<gt> 1> so the service exits on
        its own once the run completes.

=item * Waits for the service to exit.

=item * Tallies pass/fail from the per-job C<0.json> sidecars under
        C<$workdir/logs/runs/>.

=item * Exits 0 if every job passed; exits 1 if any job failed; exits
        2 on a usage error (missing args, bad paths, crashed setup).

=back

Rendering is not hooked up in this stage — pretty output arrives in
Stage 12.

=head1 SYNOPSIS

    perl -Ilib scripts/yath test t/AI/unit/Util.t
    perl -Ilib scripts/yath test t/AI/unit/

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
