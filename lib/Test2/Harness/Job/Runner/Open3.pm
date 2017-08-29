package Test2::Harness::Job::Runner::Open3;
use strict;
use warnings;

our $VERSION = '0.001001';

use IPC::Open3 qw/open3/;
use Test2::Harness::Util qw/open_file write_file/;

use File::Spec();

sub viable { 1 }

sub find_inc {
    my $class = shift;

    # Find out where Test2::Harness::Run::Worker came from, make sure that is in our workers @INC
    my $inc = $INC{"Test2/Harness/Job/Runner.pm"};
    $inc =~ s{/Test2/Harness/Job/Runner\.pm$}{}g;
    return File::Spec->rel2abs($inc);
}


sub run {
    my $class = shift;
    my ($test) = @_;

    my ($in_file, $out_file, $err_file, $event_file) = $test->output_filenames;

    my $out_fh = open_file($out_file, '>');
    my $err_fh = open_file($err_file, '>');

    write_file($in_file, $test->input);
    my $in_fh = open_file($in_file, '<');

    my $env = {
        %{$test->env_vars},
        T2_FORMATTER => 'Stream',
    };

    my @cmd = (
        $^X,
        (map { "-I$_" } @{$test->libs}, $class->find_inc),
        $ENV{HARNESS_PERL_SWITCHES} ? $ENV{HARNESS_PERL_SWITCHES} : (),
        @{$test->switches},
        $test->no_stream ? () : ("-MTest2::Formatter::Stream=file,$event_file"),
        $test->file,
        @{$test->args},
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
