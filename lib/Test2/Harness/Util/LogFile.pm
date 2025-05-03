package Test2::Harness::Util::LogFile;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/confess/;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Harness::Event;

use Test2::Harness::Util::HashBase qw{
    <name
    <fh
    <client
    <old_size
    <buffer
};

sub init {
    my $self = shift;

    if (my $client = $self->{+CLIENT}) {
        $self->{+NAME} //= $client->send_and_get('log_file');
    }

    my $file = $self->{+NAME} // confess "'name' is a required attribute unless 'client' is specified";
    confess "'$file' is not a valid log file" unless -f $file;

    open(my $fh, '<', $file) or confess "Could not open log file '$file' for reading: $!";
    $fh->blocking(0);
    $self->{+FH} = $fh;

    $self->{+OLD_SIZE} = 0;

    $self->{+BUFFER} = "";
}

sub poll {
    my $self = shift;

    my $log_file = $self->{+NAME};

    my $fh = $self->{+FH};

    my @out;

    my $new_size = -s $log_file // return undef;

    if ($new_size != $self->{+OLD_SIZE}) {
        $self->{+OLD_SIZE} = $new_size;
        seek($fh, 0, 1);

        while (my $line = <$fh>) {
            if (chomp($line)) {
                if (my $b = $self->{+BUFFER}) {
                    $line = $b . $line;
                    $self->{+BUFFER} = '';
                }

                my $event = decode_json($line);
                push @out => Test2::Harness::Event->new(%$event);
            }
            else {
                $self->{+BUFFER} .= $line;
            }
        }
    }

    return @out;
}

1;


__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::LogFile - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

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


=pod

=cut POD NEEDS AUDIT

