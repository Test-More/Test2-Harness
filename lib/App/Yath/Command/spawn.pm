package App::Yath::Command::spawn;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Util qw/find_yath/;
use Test2::Util qw/pkg_to_file/;
use File::Spec;

# If FindBin is installed, go ahead and load it. We do not care much about
# success vs failure here.
BEGIN {
    local $@;
    eval { require FindBin; FindBin->import };
}

use Carp qw/confess/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub internal_only { 1 }
sub summary       { '"Magic" command to spawn the runner that does the actual work' }
sub description   { '"Magic" command to spawn the runner that does the actual work' }
sub group         { "internal" }
sub doc_args      { (qw/runner_class directory ...args.../) }

sub init { confess(ref($_[0]) . " is not intended to be instantiated") }
sub run  { confess(ref($_[0]) . " does not implement run()") }

sub generate_run_sub {
    my $class = shift;
    my ($symbol, $argv) = @_;
    my ($runner_class, $dir, %args) = @$argv;

    if (delete $args{setsid}) {
        require POSIX;
        POSIX::setsid();
    }

    $0 = 'yath-runner';

    my $file = pkg_to_file($runner_class);
    require $file;
    my $spawn = $runner_class->new(dir => $dir, script => find_yath(), %args);

    my $test = $spawn->start;

    unless ($test) {
        my $complete = File::Spec->catfile($dir, 'complete');
        open(my $fh, '>', $complete) or die "Could not open '$complete'";
        print $fh '1';
        close($fh);
        exit 0;
    }

    # Do not keep these signal handlers post-fork when we are running a test file.
    $SIG{HUP}  = 'DEFAULT';
    $SIG{INT}  = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';

    require goto::file;

    if (ref($test) eq 'CODE') {
        goto::file->import(['exit($App::Yath::RUN->());']);

        no strict 'refs';
        return *{$symbol} = $test;
    }
    else {
        goto::file->import(File::Spec->abs2rel($test));
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::spawn - TODO

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

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
