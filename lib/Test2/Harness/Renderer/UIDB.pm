package Test2::Harness::Renderer::UIDB;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Config;
use Test2::Harness::UI::RunProcessor;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util qw/mod2file/;

our $VERSION = '0.000036';

use parent 'Test2::Harness::Renderer';
use Test2::Harness::Util::HashBase qw{
    <run
    <processor
    <config
    <dbh
    <project
    <user
    <finished
};

sub init {
    my $self = shift;

    my $settings = $self->settings;

    my $yath = $settings->yathui;
    $self->{+PROJECT} //= $yath->project || die "The yathui-project option is required.\n";
    $self->{+USER} //= $yath->user || die "The yathui-user option is required.\n";

    my $config = $self->{+CONFIG};

    unless ($config) {
        my $db = $settings->prefix('yathui-db') or die "No DB settings";

        if (my $cmod = $db->config) {
            my $file = mod2file($cmod);
            require $file;

            $config = $cmod->yath_ui_config(%$db);
        }
        else {
            my $dsn = $db->dsn;

            unless ($dsn) {
                $dsn = "";

                my $driver = $db->driver;
                my $name   = $db->name;

                $dsn .= "dbi:$driver"  if $driver;
                $dsn .= ":dname=$name" if $name;

                if (my $socket = $db->socket) {
                    my $ld = lc($driver);
                    if ($ld eq 'pg') {
                        $dsn .= ";host=$socket";
                    }
                    else {
                        $dsn .= ";${ld}_socket=$socket";
                    }
                }
                else {
                    my $host = $db->host;
                    my $port = $db->port;

                    $dsn .= ";host=$host" if $host;
                    $dsn .= ";port=$port" if $port;
                }
            }

            $config = Test2::Harness::UI::Config->new(
                dbi_dsn  => $dsn,
                dbi_user => $db->user // '',
                dbi_pass => $db->pass // '',
            );
        }
        $self->{+CONFIG} = $config;
    }

    $config->connect // die "Could not connect to the db";
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
    my ($event) = @_;

    my $f = $event->{facet_data};

    if (my $runf = $f->{harness_run}) {
        my $run_id = $runf->{run_id} or die "No run-id?";

        my $config = $self->{+CONFIG};

        my $p = $config->schema->resultset('Project')->find_or_create({name => $self->{+PROJECT}, project_id => gen_uuid()});
        my $u = $config->schema->resultset('User')->find_or_create({username => $self->{+USER}, user_id => gen_uuid(), role => 'user'});

        my $run = $config->schema->resultset('Run')->create({
            run_id     => $run_id,
            mode       => $self->settings->yathui->mode,
            status     => 'pending',
            user_id    => $u->user_id,
            project_id => $p->project_id,
        });

        $self->{+RUN} = $run;

        my $processor = Test2::Harness::UI::RunProcessor->new(
            config => $config,
            run => $run,
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

    $self->{+PROCESSOR}->finish();

    $self->{+FINISHED} = 1;
}

sub DESTROY {
    my $self = shift;

    return if $self->{+FINISHED};

    my $run = $self->{+RUN} or return;
    $run->update({status => 'broken', error => 'Run did not finish'});
}

1;
