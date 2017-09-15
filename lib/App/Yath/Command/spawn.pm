package App::Yath::Command::spawn;
use strict;
use warnings;

our $VERSION = '0.001014';

use Test2::Util qw/pkg_to_file/;
use File::Spec;

use Carp qw/confess/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub internal_only   { 1 }
sub has_jobs        { 0 }
sub has_runner      { 0 }
sub has_logger      { 0 }
sub has_display     { 0 }
sub show_bench      { 0 }
sub always_keep_dir { 0 }
sub manage_runner   { 0 }
sub summary         { "For internal use only" }
sub name            { 'spawn' }

my $TEST;

sub init { confess(ref($_[0]) . " is not intended to be instanciated") }
sub run  { confess(ref($_[0]) . " does not implement run()") }

sub import {
    my $class = shift;
    my ($argv, $runref) = @_;
    my ($runner_class, $dir, %args) = @$argv;

    if ($args{setsid}) {
        require POSIX;
        POSIX::setsid();
    }

    my $pid = $$;

    eval <<'    EOT' or die $@ if $args{pfile};
        END {
            local ($?, $!, $@);
            if (-f $args{pfile} && $pid == $$) {
                print "Deleting $args{pfile}\n";
                unlink($args{pfile}) or warn "Could not delete $args{pfile}: $!\n";
            }
        }

        1;
    EOT

    my $file = pkg_to_file($runner_class);
    require $file;
    my $spawn = $runner_class->new(dir => $dir);

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
        return $$runref = $test;
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
