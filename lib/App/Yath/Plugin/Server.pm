package App::Yath::Plugin::Server;
use strict;
use warnings;

our $VERSION = '2.000000';

die "Get rid of this file";

1;


# Move cover stuff to cover plugin
#
# move duration to finder
#
# Handle rerun
#
# move publish to client-publish
#
# [POST] server/publish/project

__END__
package App::Yath::Plugin::Server;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec;
use Test2::Harness::Util qw/read_file mod2file looks_like_uuid/;
use Test2::Harness::Util::JSON qw/decode_json/;

use Getopt::Yath;
use parent 'App::Yath::Plugin';

include_options(
    'App::Yath::Options::Server',
);

sub can_finder {
    my ($option, $options) = @_;

    return 1 if $options->included->{'App::Yath::Options::Finder'};
    return 0;
}

sub can_render {
    my ($option, $options) = @_;

    return 1 if $options->included->{'App::Yath::Options::Render'};
    return 0;
}

option_group {prefix => 'server', group => 'server', category => "Server Options"} => sub {
    option durations => (
        type => 'Bool',
        description => "Poll duration data from your server to help order tests efficiently",
        default => 0,
        applicable => \&can_finder,
    );

    option coverage => (
        type => 'Bool',
        description => "Poll coverage data from your server to determine what tests should be run for changed files",
        default => 0,
        applicable => \&can_finder,
    );

    option medium_duration => (
        type => 'Scalar',
        description => "Minimum duration length (seconds) before a test goes from SHORT to MEDIUM",
        long_examples => [' 5'],
        default => 5,
    );

    option long_duration => (
        type => 'Scalar',
        description => "Minimum duration length (seconds) before a test goes from MEDIUM to LONG",
        long_examples => [' 10'],
        default => 10,
    );

    option publish => (
        type => 'Bool',
        description => 'Publish the log to the server when the run is complete',
        notes => 'This will enable logging if it is not already enabled',
        default => 0,
        applicable => \&can_render,
    );

    option_post_process -1 => sub {
        my ($options, $state) = @_;

        my $settings = $state->{settings};

        my $has_finder = $options->included->{'App::Yath::Options::Finder'};
        my $has_render = $options->included->{'App::Yath::Options::Renderer'};

        my $has_durations = $has_finder && $settings->server->durations;
        my $has_publish   = $has_render && $settings->server->publish;
        my $has_coverage  = $has_finder && $settings->server->coverage;

        return unless $has_durations || $has_publish || $has_coverage;

        my $project = $settings->yath->project or die "'--project NAME' is required to use durations, coverage, or upload a log";
        my $url     = $settings->server->url   or die "'--server-url URL' is required to use durations, coverage, or upload a log";
        my $grace   = $settings->server->grace;

        $url =~ s{/+$}{}g;

        if ($has_render) {
            die "fixme";
            $settings->logging->option(log => 1);
            $settings->logging->option(bzip2 => 1);
        }

        if ($has_coverage) {
            my $curl = join '/' => ($url, 'coverage', $project);
            $settings->cover->option(($grace ? 'maybe_from' : 'from'), $curl);
        }

        if ($has_durations) {
            my $med  = $settings->yathui->medium_duration;
            my $long = $settings->yathui->long_duration;

            my $durl = join '/' => ($url, 'durations', $project, $med, $long);
            $settings->finder->option(($grace ? 'maybe_durations' : 'durations'), $durl);
        }

        return;
    };
};

sub grab_rerun {
    my $this = shift;
    my ($rerun, %params) = @_;

    return (0) if $rerun =~ m/\.jsonl(\.gz|\.bz2)?/;

    my $settings  = $params{settings};
    my $mode_hash = $params{mode_hash};

    my $path;
    if ($rerun eq '1') {
        my $project = $settings->yath->project or return (0);
        my $user = $settings->yath->user // $ENV{USER};

        $path = "$project/$user";

        print "Re-run requested with no paremeters, ${ \__PACKAGE__ } querying YathUI (web request) for last run matching $path...\n";

        # API Qwerk :-/
        $path .= '/0';
    }
    elsif (looks_like_uuid($rerun)) {
        $path = "$rerun";
        print "Re-run requested with UUID, ${ \__PACKAGE__ } querying YathUI (web request) for matching run, or latest run from project or user matching the UUID\n";
    }
    else {
        return (0);
    }

    $path = "rerun/$path";

    my ($ok, $res, $data) = $this->_request($settings, $path, {json => 1});

    if (!$ok) {
        print "Error getting a re-run data from yathui: $data...\n";
        return (1);
    }

    return (1, $data);
}

sub _request {
    my $this = shift;
    my ($settings, $path, $payload) = @_;

    my $url = $settings->yathui->url;
    $url =~ s{/+$}{}g;
    $url = join "/" => ($url, $path);

    my %fields;

    for my $field (qw/project api_key mode/) {
        my $val = $settings->yathui->field($field) or next;
        $fields{$field} = $val;
    }

    require HTTP::Tiny;
    eval { require HTTP::Tiny::Multipart; 1 } or die "To use --yathui-* you must install HTTP::Tiny::Multipart.\n";

    my $res;
    for (0 .. $settings->yathui->retry) {
        my $http = HTTP::Tiny->new;
        $res  = $http->post_multipart(
            $url => {
                headers => {'Content-Type' => 'application/json'},
                %fields,
                %$payload,
            },
        );

        next unless $res;
        last if $res->{status} eq '200';
    }

    my ($ok, $msg);
    if ($res && $res->{status} eq '200') {
        my $data;
        $ok = eval { $data = decode_json($res->{content}); 1 };
        if ($ok) {
            return (1, $res, $data);
        }
        else {
            $msg = $@;
        }
    }
    else {
        if ($res) {
            $msg = "Server responded with " . $res->{status} . ":\n" . ($res->{content} // 'NO CONTENT');
        }
        else {
            $msg = "Failed to upload yathui log, no response object";
        }
    }

    return (0, $res, $msg);
}

sub finish {
    my $this = shift;
    my %params = @_;

    my $settings = $params{settings};

    return unless $settings->yathui->upload;

    my $log_file = $settings->logging->log_file;
    my ($filename) = reverse File::Spec->splitpath($log_file);

    my ($ok, $res, $data) = $this->_request(
        'upload', {
            log_file => {
                filename     => $filename,
                content      => read_file($log_file, no_decompress => 1),
                content_type => 'application/x-bzip2',
            },

            action => 'Upload Log',
            json   => 1,
        }
    );

    die "Error connecting to YathUI: $data\n"
        unless $ok;

    my $msg;
    if ($data->{errors} && @{$data->{errors}}) {
        $ok  = 0;
        $msg = join "\n" => (@{$data->{errors}});
    }
    elsif ($data->{messages}) {
        $ok = 1;

        my $url = $settings->yathui->url;
        $url =~ s{/+$}{}g;

        $msg = join "\n" => (
            @{$data->{messages}},
            $data->{run_id} ? ("YathUI run url: " . join '/' => ($url, 'run', $data->{run_id})) : (),
        );
    }
    else {
        $ok  = 0;
        $msg = "No messages recieved";
    }

    chomp($msg);
    $msg = "YathUI Upload: $msg";
    if ($ok) {
        print "\n$msg\n";
    }
    else {
        if ($settings->yathui->grace) {
            warn $msg;
        }
        else {
            die $msg;
        }
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin::YathUI - Plugin to interact with a YathUI server

=head1 DESCRIPTION

If you have a Yath-UI L<App::Yath::Server> server, you can use this module to
have yath automatically upload logs or retrieve durations data

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
