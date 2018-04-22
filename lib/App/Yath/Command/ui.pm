package App::Yath::Command::ui;
use strict;
use warnings;

our $VERSION = '0.001066';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::UI::Util qw/share_dir/;

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

    $ENV{"T2_HARNESS_UI_ENV"} = 'dev';
    my $settings = $self->{+SETTINGS};

    my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});

    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => 'schema/postgresql.sql');
    my $dsn = $db->connect_string('harness_ui');
    $dbh = undef;

    $ENV{HARNESS_UI_DSN} = $dsn;

    my $config = Test2::Harness::UI::Config->new(
        dbi_dsn     => $dsn,
        dbi_user    => '',
        dbi_pass    => '',
        single_user => 1,
        single_run  => 1,
    );

    my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root'});

    open(my $lf, '<', $settings->{log_file}) or die "Could no open log file: $!";
    $config->schema->resultset('Run')->create(
        {
            user_id       => $user->user_id,
            permissions   => 'public',
            mode          => 'complete',
            status        => 'pending',
            project       => 'default',

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

App::Yath::Command::replay - Command to replay a test run from an event log.

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
