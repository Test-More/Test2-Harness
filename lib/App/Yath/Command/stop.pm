package App::Yath::Command::stop;
use strict;
use warnings;

our $VERSION = '0.001100';

use Time::HiRes qw/sleep/;

use File::Spec();

use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::Queue();

use App::Yath::Util qw/find_pfile PFILE_NAME/;
use Test2::Harness::Util qw/open_file/;
use File::Path qw/remove_tree/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Stop the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will stop a persistent instance, and output any log contents.
    EOT
}

sub run {
    my $self = shift;

    my $pfile = find_pfile()
        or die "Could not find " . PFILE_NAME() . " in current directory, or any parent directories.\n";

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    my $dir = $data->{dir};

    my $run_queue_file = File::Spec->catfile($dir, 'run_queue.jsonl');
    if (-f $run_queue_file) {
        my $run_queue = Test2::Harness::Util::Queue->new(file => $run_queue_file);
        $run_queue->end;
    }
    else {
        print "Could not find queue file, sending SIGTERM instead\n";
        kill('TERM', $data->{pid});
    }

    sleep(0.02) while kill(0, $data->{pid});

    unlink($pfile) if -f $pfile;

    remove_tree($dir, {safe => 1, keep_root => 0}) if -d $dir;

    print "\n\nRunner stopped\n\n";
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
