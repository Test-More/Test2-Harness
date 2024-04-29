package App::Yath::Command::db::publish;
use strict;
use warnings;

our $VERSION = '2.000000';

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip  qw($GunzipError);

use App::Yath::Schema::Util qw/schema_config_from_settings/;
use Test2::Harness::Util::JSON qw/decode_json/;

use App::Yath::Schema::RunProcessor;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::DB',
    'App::Yath::Options::Publish',
);

option_group {group => 'publish', prefix => 'publish', category => "Publish Options"} => sub {
    option flush_interval => (
        type => 'Scalar',
        long_examples => [' 2', ' 1.5'],
        description => 'When buffering DB writes, force a flush when an event is recieved at least N seconds after the last flush.',
    );

    option buffering => (
        type => 'Scalar',
        long_examples => [ ' none', ' job', ' diag', ' run' ],
        description => 'Type of buffering to use, if "none" then events are written to the db one at a time, which is SLOW',
        default => 'diag',
    );
};

sub summary { "Publish a log file directly to a yath database" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2]" }

sub description { "Publish a log file directly to a yath database" }

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    shift @$args if @$args && $args->[0] eq '--';

    my $file = shift @$args or die "You must specify a log file";
    die "'$file' is not a valid log file" unless -f $file;
    die "'$file' does not look like a log file" unless $file =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $fh;
    if ($file =~ m/\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new($file) or die "Could not open bz2 file: $Bunzip2Error";
    }
    elsif ($file =~ m/\.gz$/) {
        $fh = IO::Uncompress::Gunzip->new($file) or die "Could not open gz file: $GunzipError";
    }
    else {
        open($fh, '<', $file) or die "Could not open log file: $!";
    }

    my $config = schema_config_from_settings($settings);

    my $user = $settings->yath->user;

    my $is_term = -t STDOUT ? 1 : 0;

    print "\n" if $is_term;

    my $cb = App::Yath::Schema::RunProcessor->process_lines($settings);

    local $| = 1;
    while (my $line = <$fh>) {
        my $ln = $.;

        print "\033[Fprocessing log line: $ln\n"
            if $is_term;

        next if $line =~ m/^null$/ims;

        $cb->($line);
    }

    $cb->();

    print "Upload Complete\n";

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::publish - FIXME

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

