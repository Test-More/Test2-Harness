package Test2::Formatter::QVF;
use strict;
use warnings;

our $VERSION = '1.000155';

BEGIN { require Test2::Formatter::Test2; our @ISA = qw(Test2::Formatter::Test2) }

use Test2::Util::HashBase qw{
    -job_buffers
    -real_verbose
};

sub init {
    my $self = shift;
    $self->SUPER::init();

    $self->{+REAL_VERBOSE} = $self->{+VERBOSE};

    $self->{+VERBOSE} ||= 100;
}

sub update_active_disp {
    my $self = shift;
    my ($f) = @_;

    return if $f && $f->{__RENDER__}->{update_active_disp}++;

    $self->SUPER::update_active_disp($f);
}

sub write {
    my ($self, $e, $num, $f) = @_;

    return $self->SUPER::write($e, $num, $f) if $self->{+REAL_VERBOSE};

    $f ||= $e->facet_data;

    my $job_id = $f->{harness}->{job_id};

    push @{$self->{+JOB_BUFFERS}->{$job_id}} => [$e, $num, $f]
        if $job_id;

    my $show = $self->update_active_disp($f);

    if ($f->{harness_job_end} || !$job_id) {
        $show = 1;

        my $buffer = delete $self->{+JOB_BUFFERS}->{$job_id};

        if($f->{harness_job_end}->{fail}) {
            $self->SUPER::write(@{$_}) for @$buffer;
        }
        else {
            $f->{info} = [grep { $_->{tag} ne 'TIME' } @{$f->{info}}] if $f->{info};
            $self->SUPER::write($e, $num, $f)
        }
    }

    $self->{+ECOUNT}++;

    return unless $self->{+TTY};
    return unless $self->{+PROGRESS};

    $show ||= 1 unless $self->{+ECOUNT} % 10;

    if ($show) {
        # Local is expensive! Only do it if we really need to.
        local($\, $,) = (undef, '') if $\ || $,;

        my $io = $self->{+IO};
        if ($self->{+_BUFFERED}) {
            print $io "\r\e[K";
            $self->{+_BUFFERED} = 0;
        }

        print $io $self->render_status($f);
        $self->{+_BUFFERED} = 1;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::QVF - Test2 formatter that is [Q]uiet but [V]erbose on
[F]ailure.

=head1 DESCRIPTION

This formatter is a subclass of L<Test2::Formatter::Test2>. This one will
buffer all output from a test file and only show it to you if there is a
failure. Most of the time it willonly show you the completion notifications for
each test.

=head1 SYNOPSIS

    $ yath test --qvf ...

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

