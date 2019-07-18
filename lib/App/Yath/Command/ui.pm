package App::Yath::Command::ui;
use strict;
use warnings;

our $VERSION = '0.000004';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::UI::Util qw/share_dir share_file/;

use Test2::Harness::Feeder::JSONL;
use Test2::Harness::UI::Config;
use Test2::Harness::UI::Importer;
use Test2::Harness::UI;
use Test2::Harness;

use DBIx::QuickDB;
use Plack::Builder;
use Plack::App::Directory;
use Plack::Runner;

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase;

sub summary { "Launch a standalone Test2-Harness-UI server for a log file" }

sub group { 'log' }

sub has_runner  { 0 }
sub has_logger  { 0 }
sub has_display { 0 }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2]" }

sub description {
    return <<"    EOT";
    EOT
}

sub handle_list_args {
    my $self = shift;
    my ($list) = @_;

    my $settings = $self->{+SETTINGS};

    my ($log, @jobs) = @$list;

    $settings->{log_file} = $log;

    die "You must specify a log file.\n"
        unless $log;

    die "Invalid log file: '$log'"
        unless -f $log;
}

sub run_command {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});

    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => share_file('schema/postgresql.sql'));
    my $dsn = $db->connect_string('harness_ui');
    $dbh = undef;

    $ENV{HARNESS_UI_DSN} = $dsn;

    print "DSN: $dsn\n";
    my $config = Test2::Harness::UI::Config->new(
        dbi_dsn     => $dsn,
        dbi_user    => '',
        dbi_pass    => '',
        single_user => 1,
        single_run  => 1,
    );

    my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root'});
    my $proj = $config->schema->resultset('Project')->create({name => 'default'});

    open(my $lf, '<', $settings->{log_file}) or die "Could no open log file: $!";
    $config->schema->resultset('Run')->create(
        {
            user_id    => $user->user_id,
            mode       => 'complete',
            status     => 'pending',
            project_id => $proj->project_id,

            log_file => {
                name => $settings->{log_file},
                data => do { local $/; <$lf> },
            },
        }
    );

    Test2::Harness::UI::Importer->new(config => $config)->run(1);

    my $app = builder {
        mount '/js'  => Plack::App::Directory->new({root => share_dir('js')})->to_app;
        mount '/css' => Plack::App::Directory->new({root => share_dir('css')})->to_app;

        mount '/' => sub {
            Test2::Harness::UI->new(config => $config)->to_app->(@_);
        };
    };

    my $r = Plack::Runner->new;
    $r->parse_options("--server", "Starman");
    $r->run($app);

    return 1;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::ui - Command to view a test log via a web UI.

=head1 COMMAND LINE USAGE

    yath ui path/to/log/file.jsonl.gz
    yath ui path/to/log/file.jsonl.bz2

The command will give you a portnumberon your localhost to visit in your web
browser.

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
