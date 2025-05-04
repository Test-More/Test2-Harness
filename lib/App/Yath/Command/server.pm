package App::Yath::Command::server;
use strict;
use warnings;

use feature 'state';

use App::Yath::Server;

use App::Yath::Schema::Util qw/schema_config_from_settings format_uuid_for_db/;
use Test2::Util::UUID qw/gen_uuid/;
use App::Yath::Schema::ImportModes qw/is_mode/;

use Test2::Harness::Util qw/clean_path/;

our $VERSION = '2.000007';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    <server
    <config
};

sub summary     { "Start a yath web server" }
sub description { "Starts a web server that can be used to view test runs in a web browser" }
sub group       { "server" }

sub cli_args { "[log1.jsonl[.gz|.bz2] [log2.jsonl[.gz|.bz2]]]" }
sub cli_dot  { "[:: STARMAN/PLACKUP ARGS]" }

sub accepts_dot_args { 1 }

sub set_dot_args {
    my $class = shift;
    my ($settings, $dot_args) = @_;
    push @{$settings->webserver->launcher_args} => @$dot_args;
    return;
}

use Getopt::Yath;
include_options(
    'App::Yath::Options::Term',
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::WebServer',
    'App::Yath::Options::Server',
);

option_group {group => 'server', category => "Server Options"} => sub {
    option dev => (
        type => 'Bool',
        default => 0,
        description => 'Launches in "developer mode" which accepts some developer commands while the server is running.',
    );
};


sub run {
    my $self = shift;
    my $pid = $$;

    $0 = "yath-server";

    my $args = $self->args;
    my $settings = $self->settings;

    my $dev       = $settings->server->dev;
    my $shell     = $settings->server->shell;
    my $daemon    = $settings->server->daemon;
    my $ephemeral = $settings->server->ephemeral;

    die "Cannot combine --dev, --shell, and/or --daemon.\n" if ($dev && $daemon) || ($dev && $shell) || ($shell && $daemon);

    if ($daemon) {
        my $pid = fork // die "Could not fork";
        exit(0) if $pid;

        POSIX::setsid();
        setpgrp(0, 0);

        $pid = fork // die "Could not fork";
        exit(0) if $pid;

        open(STDOUT, '>>', '/dev/null');
        open(STDERR, '>>', '/dev/null');
    }

    my $config = $self->{+CONFIG} = schema_config_from_settings($settings, ephemeral => $ephemeral);

    my $qdb_params = {
        single_user => $settings->server->single_user // 0,
        single_run  => $settings->server->single_run  // 0,
        no_upload   => $settings->server->no_upload   // 0,
        email       => $settings->server->email       // undef,
    };

    my $server = $self->{+SERVER} = App::Yath::Server->new(schema_config => $config, $settings->webserver->all, qdb_params => $qdb_params);
    $server->start_server;

    my $user = $config->schema->resultset('User')->create({username => $ENV{USER}, password => 'password', realname => $ENV{USER}});
    my $api_key = $config->schema->resultset('ApiKey')->create({value => format_uuid_for_db(gen_uuid()), user_id => $user->user_id, name => "ephemeral"});
    $ENV{YATH_API_KEY} = $api_key->value;

    my $done = 0;
    $SIG{TERM} = sub { $done++; print "Caught SIGTERM shutting down...\n" unless $daemon; $SIG{TERM} = 'DEFAULT' };
    $SIG{INT}  = sub { $done++; print "Caught SIGINT shutting down...\n"  unless $daemon; $SIG{INT}  = 'DEFAULT' };

    for my $log (@{$args // []}) {
        $self->load_file($log);
    }

    sleep 1;

    $ENV{YATH_URL} = "http://" . $settings->webserver->host . ":" . $settings->webserver->port . "/";
    print "\nYath URL: $ENV{YATH_URL}\n\n";

    if ($shell) {
        local $ENV{YATH_SHELL} = 1;
        system($ENV{SHELL});
    }
    else {
        SERVER_LOOP: until ($done) {
            if ($dev && !$daemon) {
                $ENV{T2_HARNESS_SERVER_DEV} = 1;

                unless(eval { $done = $self->shell($pid); 1 }) {
                    warn $@;
                    $done = 1;
                }
            }
            else {
                sleep 1;
            }
        }
    }

    if ($pid == $$) {
        $server->stop_server if $server->pid;
    }
    else {
        die "Scope leak, wrong PID";
    }

    return 0;
}


sub load_file {
    my $self = shift;
    my ($file, $mode, $project) = @_;

    my $config = $self->{+CONFIG};

    die "No .jsonl[.*] log file provided.\n" unless $file;
    die "Invalid log file '$file': File not found, or not a normal file.\n" unless -f $file;
    $file = clean_path($file);

    $mode //= 'complete';

    state %projects;

    unless($project) {
        my $base = $file;
        $base =~ s{^.*/}{}g;
        $base =~ s{\.jsonl.*$}{}g;
        $base =~ s/-\d.*$//g;
        $project = $base || "devshell";
    }

    unless ($projects{$project}) {
        my $p = $config->schema->resultset('Project')->find_or_create({name => $project});
        $projects{$project} = $p;
    }

    my $logfile = $config->schema->resultset('LogFile')->create({
        name        => $file,
        local_file  => $file =~ m{^/} ? $file : "./demo/$file",
    });

    state $user = $config->schema->resultset('User')->find_or_create({username => 'root', password => 'root', realname => 'root'});

    my $run = $config->schema->resultset('Run')->create({
        run_uuid   => format_uuid_for_db(gen_uuid()),
        user_id    => $user->user_id,
        mode       => $mode,
        status     => 'pending',
        canon      => 1,
        project_id => $projects{$project}->project_id,

        log_file_id => $logfile->log_file_id,
    });

    return $run;
}

sub shell {
    my $self = shift;
    my ($pid) = @_;

    # Return that we should exit if the PID is wrong.
    return 1 unless $pid == $$;

    my $settings = $self->settings;
    my $server = $self->{+SERVER};
    my $config = $self->{+CONFIG};

    $SIG{TERM} = sub { $SIG{TERM} = 'DEFAULT'; die "Cought SIGTERM exiting...\n" };
    $SIG{INT}  = sub { $SIG{INT}  = 'DEFAULT'; die "Cought SIGINT exiting...\n" };

    STDERR->autoflush();

    my $dsn = $config->dbi_dsn;

    print "DBI_DSN: $dsn\n\n";
    print "\n";
    print "| Yath Server Developer Shell       |\n";
    print "| type 'help', 'h', or '?' for help |\n";

    use Term::ReadLine;
    my $term   = Term::ReadLine->new('Yath dev console');
    my $OUT    = $term->OUT || \*STDOUT;

    my $cmds = $self->command_list();
    $term->Attribs->{'attempted_completion_function'} = sub {
        my ($text, $start, $end) = @_;

        if ($start !~ m/\s/) {
            my @found;
            for my $set (@$cmds) {
                next unless $set->[0] =~ m/^\Q$text\E/;
                push @found => $set->[0];
            }

            return @found;
        }

        my ($fname) = reverse(split m/\s+/, $text);

        return Term::ReadLine::Gnu->filename_completion_function($fname // '', 0);
    };

    my $prompt = "\n> ";
    while (1) {
        my $in = $term->readline($prompt);

        return 1 if !defined($in);
        chomp($in);
        next unless length($in);

        return 1 if $in =~ m/^(q|x|exit|quit)$/;

        $term->addhistory($in);

        if ($in =~ m/^(help|h|\?)(?:\s(.+))?$/) {
            $self->shell_help($1);
            next;
        }

        my ($cmd, $args) = split /\s/, $in, 2;

        my $meth = "shell_$cmd";
        if ($self->can($meth)) {
            eval { $self->$meth($args); 1 } or warn $@;
        }
        else {
            print STDERR "Invalid command '$in'\n";
        }
    }
}

sub shell_help_text { "Show command list." }
sub shell_help {
    my $self = shift;
    my $class = ref($self);

    print "\nAvailable commands:\n";
    printf(" %-12s   %s\n", "[q]uit", "Quit the program.");
    printf(" %-12s   %s\n", "e[x]it", "Exit the program.");
    printf(" %-12s   %s\n", "[h]elp", "Show this help.");
    printf(" %-12s   %s\n", "?", "Show this help.");

    my $cmds = $self->command_list();
    for my $set (@$cmds) {
        my ($cmd, $text) = @$set;
        next if $cmd eq 'help';
        printf(" %-12s   %s\n", $cmd, $text);
    }

    print "\n";
}

sub command_list {
    my $self = shift;
    my $class = ref($self) || $self;

    my @out;

    my $stash = do { no strict 'refs'; \%{"$class\::"} };
    for my $sym (sort keys %$stash) {
        next unless $sym =~ m/^shell_(.*)/;
        my $cmd = $1;
        next if $sym =~ m/_text$/;
        next unless $self->can($sym);

        my $text = "${sym}_text";
        $text = $self->can($text) ? $self->$text() : 'No description.';

        push @out => [$cmd, $text];
    }

    return \@out;
}

sub shell_reload_text { "Restart web server (does not restart database or importers)." }
sub shell_reload { $_[0]->server->restart_server }

sub shell_reloaddb_text { "Restart database (data is lost)." }
sub shell_reloaddb {
    my $self = shift;

    my $server = $self->server;
    $server->stop_server;
    $server->stop_importers;
    $server->reset_ephemeral_db;
    $server->start_server;
}

sub shell_reloadimp_text { "Restart the importers." }
sub shell_reloadimp { $_[0]->restart_importers() }

sub shell_db_text { "Open the database." }
sub shell_db { $_[0]->server->qdb->shell('harness_ui') }

sub shell_shell_text { "Open a shell" }
sub shell_shell { $ENV{YATH_SHELL} = 1; system($ENV{SHELL}) }

sub shell_load_text { "Load a database file (filename given as argument)" }
sub shell_load {
    my $self = shift;
    my ($args) = @_;

    my ($file, $mode, $project);
    for my $part (split /\s+/, $args) {
        if (is_mode($part)) {
            die "Multiple modes provided: $mode and $part.\n" if $mode;
            $mode = $part;
        }
        elsif ($part =~ m/\.jsonl/) {
            die "Multiple files provided: $file and $part.\n" if $file;
            $file = $part;
        }
        else {
            die "Multiple projects provided: $project and $part.\n" if $project;
            $project = $part;
        }
    }

    $self->load_file($file, $mode, $project);
}

{
    no warnings 'once';
    *shell_r        = \*shell_reload;
    *shell_r_text   = \*shell_reload_text;
    *shell_rdb      = \*shell_reloaddb;
    *shell_rdb_text = \*shell_reloaddb_text;
    *shell_ri       = \*shell_reloadimp;
    *shell_ri_text  = \*shell_reloadimp_text;
    *shell_l        = \*shell_load;
    *shell_l_text   = \*shell_load_text;
    *shell_s        = \*shell_shell;
    *shell_s_text   = \*shell_shell_text;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

