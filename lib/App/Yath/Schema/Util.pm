package App::Yath::Schema::Util;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak confess/;

use Test2::Harness::Util qw/mod2file/;

use Importer Importer => 'import';

our @EXPORT = qw{
    schema_config_from_settings

    qdb_driver          dbd_driver       format_driver
    find_job            find_job_and_try
    format_duration     parse_duration

    is_invalid_subtest_name

    is_mysql
    is_postgresql
    is_sqlite
    is_percona
    is_mariadb

    format_uuid_for_db
    format_uuid_for_app
};

my %SCHEMA_TO_QDB_DRIVER = (
    sqlite     => 'SQLite',
    mariadb    => 'MariaDB',
    mysql      => 'MySQL',
    percona    => 'Percona',
    postgresql => 'PostgreSQL',
    pg         => 'PostgreSQL',
);

my %SCHEMA_TO_DBD_DRIVER = (
    sqlite     => 'DBD::SQLite',
    mariadb    => 'DBD::mysql',
    mysql      => 'DBD::mysql',
    percona    => 'DBD::mysql',
    postgresql => 'DBD::Pg',
    pg         => 'DBD::Pg',
);

my %SCHEMA_TO_FORMAT_DRIVER = (
    sqlite     => 'DateTime::Format::SQLite',
    mariadb    => 'DateTime::Format::MySQL',
    mysql      => 'DateTime::Format::MySQL',
    percona    => 'DateTime::Format::MySQL',
    postgresql => 'DateTime::Format::Pg',
    pg         => 'DateTime::Format::Pg',
);

my %BAD_ST_NAME = (
    '__ANON__'            => 1,
    'unnamed'             => 1,
    'unnamed subtest'     => 1,
    'unnamed summary'     => 1,
    '<UNNAMED ASSERTION>' => 1,
);

sub is_invalid_subtest_name {
    my ($name) = @_;
    return $BAD_ST_NAME{$name} // 0;
}

sub qdb_driver {
    my $base = base_name(@_);
    return $SCHEMA_TO_QDB_DRIVER{$base};
}

sub dbd_driver {
    my $base = base_name(@_);
    return $SCHEMA_TO_DBD_DRIVER{$base};
}

sub format_driver {
    my $base = base_name(@_);
    return $SCHEMA_TO_FORMAT_DRIVER{$base};
}

sub schema_config_from_settings {
    my ($settings, %params) = @_;

    my $config_class = delete $params{config_class} // 'App::Yath::Schema::Config';
    require(mod2file($config_class));

    my $group = $params{settings_group} // 'db';
    my $db = $settings->group($group);
    unless($db) {
        return App::Yath::Schema::Config->new(%params) if $params{ephemeral};
        confess "No database settings";
    }

    if (my $cmod = $db->config) {
        my $file = mod2file($cmod);
        require $file;

        return $cmod->yath_db_config(%$$db);
    }

    my $dsn = $db->dsn;

    unless ($dsn) {
        $dsn = "";

        my $driver = $db->driver;
        my $name   = $db->name;

        $dsn .= "dbi:$driver"  if $driver;
        $dsn .= ":dbname=$name" if $name;

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

    if ($dsn) {
        return App::Yath::Schema::Config->new(
            %params,
            dbi_dsn  => $dsn,
            dbi_user => $db->user // '',
            dbi_pass => $db->pass // '',
        );
    }

    confess "Could not find a DSN" unless $params{ephemeral};

    return App::Yath::Schema::Config->new(%params);
}

{
    no strict 'refs';
    no warnings 'once';
    *{$_} = *{"App::Yath::Schema::$_"} for qw/is_mysql is_postgresql is_sqlite is_percona is_mariadb/;
}

sub format_uuid_for_db  { App::Yath::Schema->format_uuid_for_db(@_) }
sub format_uuid_for_app { App::Yath::Schema->format_uuid_for_app(@_) }

sub find_job_and_try {
    my ($schema, $uuid, $try) = @_;

    my $job = find_job(@_);
    my $job_id = $job->job_id;

    my $job_try = find_job_try($schema, $job_id, $try);

    return ($job, $job_try);
}

sub find_job {
    my ($schema, $uuid) = @_;

    return $schema->resultset('Job')->find({job_uuid => format_uuid_for_db($uuid)});
}

sub find_job_try {
    my ($schema, $job_id, $try) = @_;

    my $job_tries = $schema->resultset('JobTry');

    if (length $try) {
        return $job_tries->search({job_id => $job_id}, {order_by => {'-desc' => 'job_try_ord'}, limit => 1})->first
            if $try == -1;

        return $job_tries->find({job_id => $job_id, job_try_ord => $try});
    }

    return $job_tries->search({job_id  => $job_id}, {order_by => {'-desc' => 'job_try_ord'}, limit => 1})->first;
}

sub base_name {
    my ($in) = @_;

    my $out = lc($in);
    $out =~ s/\.sql$//;
    $out =~ s/\d+$//g;

    return $out;
}

sub format_duration {
    my $seconds = shift;

    my $minutes = int($seconds / 60);
    my $hours   = int($minutes / 60);
    my $days    = int($hours / 24);

    $minutes %= 60;
    $hours   %= 24;

    $seconds -= $minutes * 60;
    $seconds -= $hours * 60 * 60;
    $seconds -= $days * 60 * 60 * 24;

    my @dur;
    push @dur => sprintf("%02dd", $days) if $days;
    push @dur => sprintf("%02dh", $hours) if @dur || $hours;
    push @dur => sprintf("%02dm", $minutes) if @dur || $minutes;
    push @dur => sprintf("%07.4fs", $seconds);

    return join ':' => @dur;
}

sub parse_duration {
    my $duration = shift;

    return 0 unless $duration;

    return $duration unless $duration =~ m/:?.*[dhms]$/i;

    my $out = 0;

    my (@parts) = split ':' => $duration;
    for my $part (@parts) {
        my ($num, $type) = ($part =~ m/^([0-9\.]+)([dhms])$/);

        unless ($num && $type) {
            warn "invalid duration section '$part'";
            next;
        }

        if ($type eq 'd') {
            $out += ($num * 60 * 60 * 24);
        }
        elsif ($type eq 'h') {
            $out += ($num * 60 * 60);
        }
        elsif ($type eq 'm') {
            $out += ($num * 60);
        }
        else {
            $out += $num;
        }
    }

    return $out;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Util - FIXME

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

