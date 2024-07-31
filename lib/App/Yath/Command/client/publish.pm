package App::Yath::Command::client::publish;
use strict;
use warnings;

our $VERSION = '2.000002';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Test2::Harness::Util::JSON qw/decode_json/;

use LWP;
use LWP::UserAgent;
use Getopt::Yath;

include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::WebClient',
    'App::Yath::Options::Publish' => [qw/mode/],
);

sub group { ['web client', 'log parsing'] }

sub summary { "Publish a log file to a yath web server" }

sub description {
    return <<"    EOT";
Publish a log file to a yath web server. (API key is required)
    EOT
}

sub run {
    my $self = shift;

    my $args     = $self->args;
    my $settings = $self->settings;

    shift @$args if @$args && $args->[0] eq '--';

    my $log = shift @$args or die "You must specify a log file";
    die "'$log' is not a valid log file"       unless -f $log;
    die "'$log' does not look like a log file" unless $log =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $api_key = $settings->webclient->api_key or die "No API key was specified.\n";
    my $url     = $settings->webclient->url     or die "No URL specified.\n";
    my $mode    = $settings->publish->mode      or die "No MODE specified.\n";
    my $project = $settings->yath->project      or die "No project specified.\n";

    $url =~ s{/+$}{}g;

    my $ua  = LWP::UserAgent->new;
    my $res = $ua->post(
        "$url/upload",
        'Content-Type' => 'multipart/form-data',
        'Content'      => [
            mode     => $mode,
            api_key  => $api_key,
            project  => $project,
            action   => 'upload log',
            json     => 1,
            log_file => [$log],
        ],
    );

    if ($res->is_success) {
        my $json = $res->decoded_content;
        my $data = decode_json($json);

        print "$_\n" for @{$data->{messages} // []};

        print "\nView run at: $url/view/$data->{run_uuid}\n\n";

        return 0;
    }
    else {
        print STDERR $res->status_line, "\n";
        return 1;
    }
}


1;

__END__

=head1 POD IS AUTO-GENERATED
