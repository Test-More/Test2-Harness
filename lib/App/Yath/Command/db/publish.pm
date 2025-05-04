package App::Yath::Command::db::publish;
use strict;
use warnings;

our $VERSION = '2.000007';

use Time::HiRes qw/time/;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip  qw($GunzipError);

use App::Yath::Schema::Util qw/schema_config_from_settings format_duration/;
use Test2::Harness::Util::JSON qw/decode_json/;

use App::Yath::Schema::RunProcessor;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::DB',
    'App::Yath::Options::Publish',
);

sub summary     { "Publish a log file directly to a yath database" }
sub group       { ["database", 'log parsing'] }
sub cli_args    { "[--] event_log.jsonl[.gz|.bz2]" }
sub description { "Publish a log file directly to a yath database" }

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    shift @$args if @$args && $args->[0] eq '--';

    my $file = shift @$args or die "You must specify a log file";
    die "'$file' is not a valid log file" unless -f $file;
    die "'$file' does not look like a log file" unless $file =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $lines = 0;
    my $fh;
    if ($file =~ m/\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new($file) or die "Could not open bz2 file: $Bunzip2Error";
        $lines++ while <$fh>;
        $fh = IO::Uncompress::Bunzip2->new($file) or die "Could not open bz2 file: $Bunzip2Error";
    }
    elsif ($file =~ m/\.gz$/) {
        $fh = IO::Uncompress::Gunzip->new($file) or die "Could not open gz file: $GunzipError";
        $lines++ while <$fh>;
        $fh = IO::Uncompress::Gunzip->new($file) or die "Could not open gz file: $GunzipError";
    }
    else {
        open($fh, '<', $file) or die "Could not open log file: $!";
        $lines++ while <$fh>;
        seek($fh, 0, 0);
    }

    my $user = $settings->yath->user;

    my $is_term = -t STDOUT ? 1 : 0;

    print "\n" if $is_term;

    my $project = $file;
    $project =~ s{^.*/}{}g;
    $project =~ s{\.jsonl.*$}{}g;
    $project =~ s/-\d.*$//g;
    $project =~ s/^\s+//g;
    $project =~ s/\s+$//g;

    my $start = time;

    my $cb = App::Yath::Schema::RunProcessor->process_lines($settings, project => $project, print_links => 1);

    my $run;
    eval {
        my $ln = <$fh>;
        $run = $cb->($ln);
        1
    } or return $self->fail($@);

    $SIG{INT} = sub {
        print STDERR "\nCought SIGINT...\n";
        eval { $run->update({status => 'canceled', error => "SIGINT while importing"}); 1 } or warn $@;
        exit 255;
    };

    $SIG{TERM} = sub {
        print STDERR "\nCought SIGTERM...\n";
        eval { $run->update({status => 'canceled', error => "SIGTERM while importing"}); 1 } or warn $@;
        exit 255;
    };

    my $len = length("" . $lines);

    local $| = 1;
    while (my $line = <$fh>) {
        my $ln = $.;

        printf("\033[Fprocessing '%s' line: % ${len}d / %d\n", $file, $ln, $lines)
            if $is_term;

        next if $line =~ m/^null$/ims;

        eval { $cb->($line); 1 } or return $self->fail($@, $run);
    }

    $cb->();

    my $end = time;

    my $dur = format_duration($end - $start);

    print "Published Run. [Status: " . $run->status . ", Duration: $dur]\n";

    return 0;
}

sub fail {
    print STDERR "FAIL!\n\n";
    my $self = shift;
    my ($err, $run) = @_;

    $run->update({status => 'broken', error => $err}) if $run;

    print STDERR "\n$err\n";

    print STDERR "\nPublish Failed.\n";
    return 255;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

