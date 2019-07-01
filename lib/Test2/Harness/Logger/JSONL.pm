package Test2::Harness::Logger::JSONL;
use strict;
use warnings;

our $VERSION = '0.001078';

use IO::Handle;

use Test2::Harness::Util::JSON qw/encode_json/;

BEGIN { require Test2::Harness::Logger; our @ISA = ('Test2::Harness::Logger') }
use Test2::Harness::Util::HashBase qw/-fh -prefix/;

sub init {
    my $self = shift;

    $self->{+PREFIX} = '' unless defined $self->{+PREFIX};

    unless($self->{+FH}) {
        open(my $fh, '>&', fileno(STDOUT)) or die "Could not clone STDOUT: $!";
        $fh->autoflush(1);
        $self->{+FH} = $fh;
    }
}

sub log_processed_event {
    my $self = shift;
    my ($event) = @_;

    my $fh = $self->{+FH};
    my $prefix = $self->{+PREFIX};
    print $fh $prefix, encode_json($event), "\n";
}

sub finish {
    my $self = shift;
    close($self->{+FH});
    $self->{+FH} = undef;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Logger::JSONL - Logger that writes events to a JSONL file.

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
