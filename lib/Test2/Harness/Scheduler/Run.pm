package Test2::Harness::Scheduler::Run;
use strict;
use warnings;

our $VERSION = '2.000005';

use parent 'Test2::Harness::Run';

my @NO_JSON;
BEGIN {
    @NO_JSON = qw{
        todo
        running
        complete
    };

    sub no_json {
        my $self = shift;

        return (
            $self->SUPER::no_json(),
            @NO_JSON,
        );
    }
}

use Test2::Harness::Util::HashBase(
    @NO_JSON,
    qw{
        <results
        halt
        pid
    },
);

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+COMPLETE} = [];
    $self->{+RUNNING}  = {};
    $self->{+TODO}     = {};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Scheduler::Run - FIXME

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

