package App::Yath::Command::watch;
use strict;
use warnings;

our $VERSION = '0.001078';

use Time::HiRes qw/sleep/;

use Test2::Harness::Util::File::JSON;

use App::Yath::Util qw/find_pfile/;
use Test2::Harness::Util qw/open_file/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub show_bench      { 0 }
sub has_jobs        { 0 }
sub has_runner      { 0 }
sub has_logger      { 0 }
sub has_display     { 0 }
sub manage_runner   { 0 }
sub always_keep_dir { 0 }

sub summary { "Monitor the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will tail the logs from a persistent instance of yath. STDOUT and
STDERR will be printed as seen, so may not be in proper order.
    EOT
}

sub run {
    my $self = shift;

    my $pfile = find_pfile()
        or die "No persistent harness was found for the current path.\n";

    print "\nFound: $pfile\n";
    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
    print "  PID: $data->{pid}\n";
    print "  Dir: $data->{dir}\n";
    print "\n";

    my $err_f = File::Spec->catfile($data->{dir}, 'error.log');
    my $out_f = File::Spec->catfile($data->{dir}, 'output.log');

    my $err_fh = open_file($err_f, '<');
    my $out_fh = open_file($out_f, '<');

    while (1) {
        my $count = 0;
        while (my $line = <$out_fh>) {
            $count++;
            print STDOUT $line;
        }
        while (my $line = <$err_fh>) {
            $count++;
            print STDERR $line;
        }

        next if $count;
        last unless -f $pfile;
        sleep 0.02;
    }

    return 0;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

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
