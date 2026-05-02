package Test2::Harness2::LogLayout;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Exporter qw/import/;

# Single canonical source for on-disk paths inside a yath log tree.
# Loggers, RunService, LogArchive backends, and the layout-rejection
# checks all import these helpers so the path templates live in one
# place.
#
# All returned paths are relative to the log root (no leading '/'),
# extension-less in the logical sense -- callers append '.json',
# '.jsonl', '.zst', etc. at their own layer.
#
# Do not embed compression suffixes (.zst) or alternate encodings
# (.csv, .xml) here; that is the logger's concern.

our @EXPORT_OK = qw/
    run_dir
    run_spec_basename
    run_state_basename
    run_events_basename
    run_test_basename
    services_global_dir
    services_run_dir
    service_global_dir
    service_run_dir
    service_global_basename
    service_run_basename
/;

sub run_dir {
    my ($run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return "runs/$run_id";
}

sub run_spec_basename {
    my ($run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return "runs/$run_id/spec";
}

sub run_state_basename {
    my ($run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return "runs/$run_id/state";
}

sub run_events_basename {
    my ($run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return "runs/$run_id/events";
}

sub run_test_basename {
    my ($run_id, $job_id, $job_try) = @_;
    croak "run_id is required"  unless defined $run_id  && length $run_id;
    croak "job_id is required"  unless defined $job_id  && length $job_id;
    croak "job_try is required" unless defined $job_try && length $job_try;
    return "runs/$run_id/tests/$job_id/$job_try";
}

sub services_global_dir { 'services' }

sub services_run_dir {
    my ($run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return "runs/$run_id/services";
}

sub service_global_dir {
    my ($name) = @_;
    croak "service name is required" unless defined $name && length $name;
    return "services/$name";
}

sub service_run_dir {
    my ($run_id, $name) = @_;
    croak "run_id is required"       unless defined $run_id && length $run_id;
    croak "service name is required" unless defined $name   && length $name;
    return "runs/$run_id/services/$name";
}

sub service_global_basename {
    my ($name, $leaf) = @_;
    croak "service name is required" unless defined $name && length $name;
    croak "leaf is required"         unless defined $leaf && length $leaf;
    return "services/$name/$leaf";
}

sub service_run_basename {
    my ($run_id, $name, $leaf) = @_;
    croak "run_id is required"       unless defined $run_id && length $run_id;
    croak "service name is required" unless defined $name   && length $name;
    croak "leaf is required"         unless defined $leaf   && length $leaf;
    return "runs/$run_id/services/$name/$leaf";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::LogLayout - Path templates for the yath log tree.

=head1 DESCRIPTION

Single canonical source of truth for the on-disk paths inside a yath
log tree. Importable functions return I<extension-less> relative paths.
Callers append their own suffixes (C<.json>, C<.jsonl>, C<.zst>,
future C<.csv> / C<.xml>, etc.) at their own layer.

=head1 EXPORTS

=over 4

=item $rel = run_dir($run_id)

Returns C<runs/$run_id>.

=item $rel = run_spec_basename($run_id)

Returns C<runs/$run_id/spec>.

=item $rel = run_state_basename($run_id)

Returns C<runs/$run_id/state>.

=item $rel = run_events_basename($run_id)

Returns C<runs/$run_id/events>.

=item $rel = run_test_basename($run_id, $job_id, $job_try)

Returns C<runs/$run_id/tests/$job_id/$job_try>. Per-job directory,
per-try basename. Phase 4.5 layout (changed from the previous
per-job-only basename so retries no longer clobber).

=item $rel = services_global_dir()

Returns C<services>.

=item $rel = services_run_dir($run_id)

Returns C<runs/$run_id/services>.

=item $rel = service_global_dir($name)

Returns C<services/$name>. The directory itself is the existence
signal for a global service; per-leaf log files land beneath it.

=item $rel = service_run_dir($run_id, $name)

Returns C<runs/$run_id/services/$name>. The directory itself is
the existence signal for a run-scoped service.

=item $rel = service_global_basename($name, $leaf)

Returns C<services/$name/$leaf>. Concrete loggers append their
extension (.jsonl, .json, .zst) to produce the on-disk file.

=item $rel = service_run_basename($run_id, $name, $leaf)

Returns C<runs/$run_id/services/$name/$leaf>.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
