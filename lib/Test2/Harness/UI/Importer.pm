package Test2::Harness::UI::Importer;
use strict;
use warnings;

our $VERSION = '0.000028';

use Carp qw/croak/;

use Test2::Harness::UI::Import;

use Test2::Harness::UI::Util::HashBase qw/-config/;

sub init {
    my $self = shift;

    croak "'config' is a required attribute"
        unless $self->{+CONFIG};
}

sub run {
    my $self = shift;
    my ($max) = @_;

    my $schema = $self->{+CONFIG}->schema;


    while (!defined($max) || $max--) {
        my $run = $schema->txn_do(
            sub {
                my $run = $schema->resultset('Run')->search(
                    {status => 'pending', log_file_id => {'is not' => undef}},
                    {order_by => {-asc => 'added'}, limit => 1, for => \'update skip locked'},
                )->first;
                return unless $run;

                $run->update({status => 'running'});
                return $run;
            }
        );

        unless ($run) {
            sleep 1;
            next;
        }

        $self->process($run);
    }
}

sub process {
    my $self = shift;
    my ($run) = @_;

    my $start = time;
    syswrite(\*STDOUT, "Starting run " . $run->run_id . " (" . $run->log_file->name . ")\n");

    my $status;
    my $ok = eval {
        my $import = Test2::Harness::UI::Import->new(
            config => $self->{+CONFIG},
            run    => $run,
        );

        $status = $import->process;

        1;
    };
    my $err = $@;

    my $total = time - $start;

    if ($ok && !$status->{errors}) {
        syswrite(\*STDOUT, "Completed run " . $run->run_id . " (" . $run->log_file->name . ") in $total seconds.\n");
        $run->update({status => 'complete', passed => $status->{passed}, failed => $status->{failed}, retried => $status->{retried}});
    }
    else {
        my $error = $ok ? join("\n" => @{$status->{errors}}) : $err;
        syswrite(\*STDOUT, "Failed feed " . $run->run_id . " (" . $run->log_file->name . ") in $total seconds.\n$error\n");
        $run->update({status => 'broken', error => $error});
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Importer

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

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
