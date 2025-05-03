package App::Yath::Renderer::Server;
use strict;
use warnings;

our $VERSION = '2.000005';

use App::Yath::Schema::Util qw/schema_config_from_settings/;
use App::Yath::Server;

use parent 'App::Yath::Renderer::DB';
use Test2::Harness::Util::HashBase qw{
    <config
    <server
};

use Getopt::Yath;
include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::Publish',
    'App::Yath::Options::WebServer',
    'App::Yath::Options::Server' => [qw/ephemeral/],
);

sub start {
    my $self = shift;

    # Do not use the yath workdir for these things, it will get cleaned up too soon.
    my ($dir) = grep { $_ && -d $_ } '/dev/shm', $ENV{SYSTEM_TMPDIR}, '/tmp', $ENV{TMP_DIR}, $ENV{TMPDIR};
    local $ENV{TMPDIR} = $dir;
    local $ENV{TMP_DIR} = $dir;
    local $ENV{TEMP_DIR} = $dir;

    my $settings  = $self->settings;
    my $ephemeral = $settings->server->ephemeral;
    unless ($ephemeral) {
        $ephemeral = 'Auto';
        $settings->server->ephemeral($ephemeral);
    }

    my $config = $self->{+CONFIG} //= schema_config_from_settings($settings, ephemeral => $ephemeral);

    my $qdb_params = {
        single_user => 1,
        single_run  => 1,
        no_upload   => 1,
        email       => undef,
    };

    my $server = $self->{+SERVER} = App::Yath::Server->new(schema_config => $config, $settings->webserver->all, qdb_params => $qdb_params);
    $server->start_server(no_importers => 1);

    sleep 1;

    $ENV{YATH_URL} = "http://" . $settings->webserver->host . ":" . $settings->webserver->port . "/";
    print "\nYath URL: $ENV{YATH_URL}\n\n";

    $settings->db->config($ENV{YATH_DB_CONFIG}) if $ENV{YATH_DB_CONFIG};
    $settings->db->driver($ENV{YATH_DB_DRIVER}) if $ENV{YATH_DB_DRIVER};
    $settings->db->name($ENV{YATH_DB_NAME})     if $ENV{YATH_DB_NAME};
    $settings->db->user($ENV{YATH_DB_USER})     if $ENV{YATH_DB_USER};
    $settings->db->pass($ENV{YATH_DB_PASS})     if $ENV{YATH_DB_PASS};
    $settings->db->dsn($ENV{YATH_DB_DSN})       if $ENV{YATH_DB_DSN};
    $settings->db->host($ENV{YATH_DB_HOST})     if $ENV{YATH_DB_HOST};
    $settings->db->port($ENV{YATH_DB_PORT})     if $ENV{YATH_DB_PORT};
    $settings->db->socket($ENV{YATH_DB_SOCKET}) if $ENV{YATH_DB_SOCKET};

    $self->SUPER::start();
}

sub exit_hook {
    my $self = shift;

    $self->SUPER::exit_hook(@_);

    print "\nYath URL: $ENV{YATH_URL}\n\n";
    print "Press ENTER/RETURN to stop server and exit\n";
    my $x = <STDIN>;

    delete $self->{+SERVER};
    delete $self->{+CONFIG};

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer::Server - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

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


=pod

=cut POD NEEDS AUDIT

