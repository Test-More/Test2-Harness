package Test2::Harness::UI::Importer;
use strict;
use warnings;

our $VERSION = '0.000096';

use Carp qw/croak/;

use Test2::Harness::UI::RunProcessor;

use Test2::Harness::UI::Util::HashBase qw/-config -worker_id/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/decode_json/;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip  qw($GunzipError);

sub init {
    my $self = shift;

    croak "'config' is a required attribute"
        unless $self->{+CONFIG};
}

sub run {
    my $self = shift;
    my ($max) = @_;

    my $schema = $self->{+CONFIG}->schema;

    my $worker_id = $self->{+WORKER_ID} //= gen_uuid();

    while (!defined($max) || $max--) {
        $schema->resultset('Run')->search(
            {status   => 'pending', log_file_id => {'is not' => undef}},
            {order_by => {-asc => 'added'}, rows => 1},
        )->update({status => 'running', worker_id => $worker_id});

        my $run = $schema->resultset('Run')->search(
            {status   => 'running',         worker_id => $worker_id},
            {order_by => {-asc => 'added'}, rows      => 1},
        )->first;

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
    syswrite(\*STDOUT, '[' . $run->worker_id . "] Starting run " . $run->run_id . " (" . $run->log_file->name . ")\n");

    my $status;
    my $ok = eval { $status = $self->process_log($run); 1 };
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

sub process_log {
    my $self = shift;
    my ($run, $fh) = @_;

    unless ($fh) {
        my $log = $run->log_file or die "No log file";
        if ($log->name =~ m/\.bz2$/) {
            $fh = IO::Uncompress::Bunzip2->new($log->local_file || \($log->data)) or die "Could not open bz2 data: $Bunzip2Error";
        }
        else {
            $fh = IO::Uncompress::Gunzip->new($log->local_file || \($log->data)) or die "Could not open gz data: $GunzipError";
        }
    }

    my $processor = Test2::Harness::UI::RunProcessor->new(
        run => $run,
        config => $self->{+CONFIG},
        buffer => 1,
    );

    $processor->start();

    my $schema = $self->{+CONFIG}->schema;

    local $| = 1;
    while (my $line = <$fh>) {
        next if $line =~ m/^null$/ims;
        my $ln = $.;

        my $error = $self->process_event_json($processor, $ln => $line);

        return {errors => ["error processing line number $ln: $error"]} if $error;
    }

    my $status = $processor->finish();
    return $status;
}

sub process_event_json {
    my $self = shift;
    my ($processor, $ln, $json) = @_;

    my $ok = eval {
        my $event = decode_json($json);
        $processor->process_event($event, undef, line => $ln);
        1;
    };
    my $err = $@;
    return $ok ? undef : $err;
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
