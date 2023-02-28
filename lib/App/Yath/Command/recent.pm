package App::Yath::Command::recent;
use strict;
use warnings;

our $VERSION = '0.000136';

use Term::Table;
use Test2::Harness::UI::Util qw/config_from_settings/;
use Test2::Harness::Util::JSON qw/decode_json/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use App::Yath::Options;

option_group {prefix => 'yathui', category => "List Options"} => sub {
    option max => (
        type => 's',
        long_examples => [' 10'],
        default => 10,
        description => 'Max number of recent runs to show',
    );
};

sub summary { "Show a list of recent YathUI runs" }

sub group { 'log' }

sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will find the last several runs from yathui or the yathui
database.

This command gets the username from the "--yathui-user USER" option (Defaults to \$ENV{USER}).
This command gets the project from the "--yathui-project PROJECT" option.
This command uses the "--max NUM" option to set how many runs to show (Defaults to 10).

    EOT
}

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    my $yui = $settings->yathui;
    my $ydb = $self->settings->prefix('yathui-db');
    my $config = config_from_settings($settings);

    my ($is_term, $use_color) = (0, 0);
    if (-t STDOUT) {
        require Term::Table::Cell;
        $is_term   = 1;
        $use_color = eval { require Term::ANSIColor; 1 };
    }

    my $project = $yui->project // die "--yathui-project is a required argument.\n";
    my $user    = $yui->user    // $ENV{USER};
    my $count   = $yui->max || 10;

    print "\nProject: $project\n   User: $user\n  Count: $count\n\n";

    my $data = $config->dbi_dsn
        ? $self->get_from_db($settings, $config, $project, $user, $count)
        : $self->get_from_http($settings, $yui, $project, $user, $count);

    @$data = reverse @$data;

    my $url = $yui->url;
    $url =~ s{/$}{}g if $url;

    my $header = [qw/Time Duration Status Pass Fail Retry/, "Run ID"];
    push @$header => 'Link' if $url;

    my $rows = [];
    for my $run (@$data) {
        push @$rows => [@{$run}{qw/added duration status passed failed retried run_id/}];

        if ($url) {
            push @{$rows->[-1]} => $run->{status} ne 'broken' ? "$url/view/$run->{run_id}" : "N/A";
        }

        my $color;
        if    ($run->{status} eq 'broken')   { $color = "magenta" }
        elsif ($run->{status} eq 'pending')  { $color = "blue" }
        elsif ($run->{status} eq 'running')  { $color = "blue" }
        elsif ($run->{status} eq 'canceled') { $color = "yellow" }
        elsif ($run->{failed})               { $color = "bold red" }
        elsif ($run->{retried})              { $color = "bold cyan" }
        elsif ($run->{passed})               { $color = "bold green" }

        if ($use_color && $color) {
            $_ = Term::Table::Cell->new(value => $_, value_color => Term::ANSIColor::color($color), reset_color => Term::ANSIColor::color("reset"))
                for @{$rows->[-1]};
        }
    }


    my $table = Term::Table->new(
        header => $header,
        rows => $rows,
    );

    print "$_\n" for $table->render;

    return 0;
}

sub get_from_http {
    my $self = shift;
    my ($settings, $yui, $project, $user, $count) = @_;

    require HTTP::Tiny;
    my $ht = HTTP::Tiny->new();
    my $url = $yui->url;
    $url =~ s{/$}{}g;
    $url .= "/recent/$project/$user";
    my $res = $ht->get($url);

    die "Could not get recent runs from '$url'\n$res->{status}: $res->{reason}\n$res->{content}\n"
        unless $res->{success};

    return decode_json($res->{content});
}

sub get_from_db {
    my $self = shift;
    my ($settings, $config, $project, $user, $count) = @_;

    my $schema = $config->schema;
    my $runs   = $schema->vague_run_search(
        username     => $user,
        project_name => $project,
        query        => {},
        attrs        => {order_by => {'-desc' => 'added'}, rows => $count},
        list         => 1,
    );

    my $data = [];

    while (my $run = $runs->next) {
        push @$data => $run->TO_JSON;
    }

    return $data;
}



1;
