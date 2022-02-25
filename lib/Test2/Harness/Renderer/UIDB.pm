package Test2::Harness::Renderer::UIDB;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Config;
use Test2::Harness::UI::RunProcessor;
use Test2::Harness::UI::Util qw/config_from_settings/;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util qw/mod2file/;

our $VERSION = '0.000110';

use parent 'Test2::Harness::Renderer';
use Test2::Harness::Util::HashBase qw{
    <run
    <processor
    <config
    <dbh
    <project
    <user
    <finished
    +links
    <error_count
};

sub init {
    my $self = shift;

    my $settings = $self->settings;

    my $yath = $settings->yathui;
    $self->{+PROJECT} //= $yath->project || die "The yathui-project option is required.\n";
    $self->{+USER} //= $yath->user || die "The yathui-user option is required.\n";

    $self->{+ERROR_COUNT} = 0;

    my $config = $self->{+CONFIG} //= config_from_settings($settings);

    $config->connect // die "Could not connect to the db";

    STDOUT->autoflush(1);
    print $self->links;
}

sub links {
    my $self = shift;
    return $self->{+LINKS} if defined $self->{+LINKS};

    if (my $url = $self->settings->yathui->url) {
        $self->{+LINKS} = "\nThis run can be reviewed at: $url/view/" . $self->settings->run->run_id . "\n\n";
    }

    return $self->{+LINKS} //= "";
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    $self->{+PROCESSOR}->set_signal($sig) if $self->{+PROCESSOR};

    my $run = $self->{+RUN} or return;
    $run->update({status => 'canceled', error => "Canceled with signal '$sig'"});
}

sub render_event {
    my $self = shift;
    my @args = @_;

    return if $self->{+ERROR_COUNT} >= 10;

    my $out;
    eval { $out = $self->_render_event(@args); 1 } and return $out;
    warn "YathUI-DB Renderer error:\n====\n$@\n====\n";

    $self->{+ERROR_COUNT}++;

    return unless $self->{+ERROR_COUNT} >= 10;
    warn "\n\n*************************\nThe YathUI-DB renderer has encountered 10+ errors, disabling...\n*************************\n\n";
}

sub _render_event {
    my $self = shift;
    my ($event) = @_;

    my $f = $event->{facet_data};

    if (my $runf = $f->{harness_run}) {
        my $run_id = $runf->{run_id} or die "No run-id?";

        my $config = $self->{+CONFIG};

        my $p = $config->schema->resultset('Project')->find_or_create({name => $self->{+PROJECT}, project_id => gen_uuid()});
        my $u = $config->schema->resultset('User')->find_or_create({username => $self->{+USER}, user_id => gen_uuid(), role => 'user'});

        my $ydb = $self->settings->prefix('yathui-db') or die "No DB settings";
        my $run = $config->schema->resultset('Run')->create({
            run_id     => $run_id,
            mode       => $self->settings->yathui->mode,
            buffer     => $ydb->buffering,
            status     => 'pending',
            user_id    => $u->user_id,
            project_id => $p->project_id,
        });

        $self->{+RUN} = $run;

        my $processor = Test2::Harness::UI::RunProcessor->new(
            config => $config,
            run => $run,
            interval => $ydb->flush_interval,
        );

        $self->{+PROCESSOR} = $processor;
        $processor->start();
    }
    elsif (!$self->{+RUN}) {
        die "Run was not seen!";
    }

    $self->{+PROCESSOR}->process_event($event, $f);
}

sub finish {
    my $self = shift;

    eval { $self->{+PROCESSOR}->finish(); 1 } or warn "YathUI-DB finish error:\n====\n$@\n====\n";

    $self->{+FINISHED} = 1;

    print $self->links;
}

sub DESTROY {
    my $self = shift;

    return if $self->{+FINISHED};

    my $run = $self->{+RUN} or return;
    $run->update({status => 'broken', error => 'Run did not finish'});
}

1;
