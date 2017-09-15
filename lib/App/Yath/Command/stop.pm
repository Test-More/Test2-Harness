package App::Yath::Command::stop;
use strict;
use warnings;

our $VERSION = '0.001015';

use File::Path qw/remove_tree/;

use File::Spec();

use Test2::Harness::Util::File::JSON();

use App::Yath::Util qw/find_pfile PFILE_NAME/;
use Test2::Harness::Util qw/open_file/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub show_bench      { 0 }
sub has_jobs        { 0 }
sub has_runner      { 0 }
sub has_logger      { 0 }
sub has_display     { 0 }
sub always_keep_dir { 0 }
sub manage_runner   { 0 }

sub summary { "Stop the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
foo bar baz
    EOT
}

sub run {
    my $self = shift;

    my $pfile = find_pfile()
        or die "Could not find " . PFILE_NAME() . " in current directory, or any parent directories.\n";

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    my $exit;
    if (kill('TERM', $data->{pid})) {
        waitpid($data->{pid}, 0);
        $exit = 0;
    }
    else {
        warn "Could not kill pid $data->{pid}.\n";
        $exit = 255;
    }

    unlink($pfile) if -f $pfile;

    my $stdout = open_file(File::Spec->catfile($data->{dir}, 'output.log'));
    my $stderr = open_file(File::Spec->catfile($data->{dir}, 'error.log'));

    print "\nSTDOUT LOG:\n";
    print "========================\n";
    while( my $line = <$stdout> ) {
        print $line;
    }
    print "\n========================\n";

    print STDERR "\nSTDERR LOG:\n";
    print STDERR "========================\n";
    while (my $line = <$stderr>) {
        print STDERR $line;
    }
    print STDERR "\n========================\n";

    remove_tree($data->{dir}, {safe => 1, keep_root => 0});

    print "\n";
    return $exit;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::persist

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
