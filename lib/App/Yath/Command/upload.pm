package App::Yath::Command::upload;
use strict;
use warnings;

our $VERSION = '0.000136';

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip  qw($GunzipError);

use Test2::Harness::UI::Util qw/ config_from_settings /;
use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Harness::Renderer::UIDB;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use App::Yath::Options;

include_options(
    'App::Yath::Options::PreCommand',
);

sub summary { "Use the YathUIDB plugin to upload a log file" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2]" }

sub description {
    return <<"    EOT";
    EOT
}

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    shift @$args if @$args && $args->[0] eq '--';

    my $file = shift @$args or die "You must specify a log file";
    die "'$file' is not a valid log file" unless -f $file;
    die "'$file' does not look like a log file" unless $file =~ m/\.jsonl(\.(gz|bz2))?$/;

    die "The YathUIDB plugin is required" unless $settings->check_prefix('yathui-db');

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

    my $config = config_from_settings($settings);

    my $ydb  = $self->settings->prefix('yathui-db');
    my $yath = $settings->yathui;
    my $user = $yath->user || $ENV{USER};

    my $renderer = Test2::Harness::Renderer::UIDB->new(
        config   => $config,
        settings => $settings,
        user     => $user,
    );

    my $is_term = -t STDOUT ? 1 : 0;

    print "\n" if $is_term;

    local $| = 1;
    while (my $line = <$fh>) {
        my $ln = $.;

        print "\033[Fprocessing log line: $ln\n"
            if $is_term;

        next if $line =~ m/^null$/ims;

        my $ok = eval {
            my $event = decode_json($line);
            $renderer->_render_event($event);
            1;
        };
        my $err = $@;
        next if $ok;

        die "Error processing log on line $ln: $err";
    }

    print "Upload Complete\n";

    $renderer->finish();

    return 0;
}

1;
