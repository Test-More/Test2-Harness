package App::Yath::Tester;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Util qw/find_yath/;
use File::Spec;
use File::Temp qw/tempfile tempdir/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use POSIX;

use Carp qw/croak/;

use Importer Importer => 'import';
our @EXPORT = qw/yath_test yath_test_with_log yath_start yath_stop yath_run yath_run_with_log/;

my $pdir = tempdir(CLEANUP => 1);

sub yath_test_with_log {
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();

    my ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
    close($fh);

    my ($exit, $out) = _yath('test', $file, $test, @options, '-F' => $logfile);

    return ($exit, Test2::Harness::Util::File::JSONL->new(name => $logfile), $out);
}

sub yath_test {
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();
    return _yath('test', $file, $test, @options);
}

sub yath_start {
    my (@options) = @_;
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my $yath = find_yath;
    my $exit = system($^X, $yath, '-D', 'start', @options);
}

sub yath_stop {
    my (@options) = @_;
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my $yath = find_yath;
    my $exit = system($^X, $yath, '-D', 'stop', @options);
}

sub yath_run {
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();
    return _yath('run', $file, $test, @options);
}

sub yath_run_with_log {
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();

    my ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
    close($fh);

    my ($exit, $out) = _yath('run', $file, $test, @options, '-F' => $logfile);

    return ($exit, Test2::Harness::Util::File::JSONL->new(name => $logfile), $out);
}


sub _yath {
    my ($cmd, $file, $test, @options) = @_;

    my $pre_opts = ref($options[0]) eq 'ARRAY' ? shift @options : [];

    my $dir = $file;
    $dir =~ s/\.t2?$//g;

    my $run = $test ? File::Spec->catfile($dir, "$test.tx") : undef;
    croak "Could not find test '$test' at '$run'" if $run && !-f $run;

    my $inc = File::Spec->catdir($dir, 'lib');
    $inc = undef unless -d $inc;

    my $yath = find_yath;

    pipe(my ($rh, $wh)) or die "Could not open pipe: $!";
    my @final = ($^X, $yath, $inc ? ("-D$inc") : (), '-D', @$pre_opts, $cmd, @options, $run ? ($run) : ());
    my $pid = run_cmd(
        stderr => $wh,
        stdout => $wh,
        command => \@final,
    );

    $rh->blocking(0);
    my (@lines, $exit);
    while(1) {
        push @lines => <$rh>;

        waitpid($pid, WNOHANG) or next;
        $exit = $?;
        last;
    }

    push @lines => <$rh>;

    return $exit unless wantarray;
    return ($exit, join '' => @lines);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Tester - Tools for testing yath

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
