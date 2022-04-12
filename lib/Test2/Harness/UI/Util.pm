package Test2::Harness::UI::Util;
use strict;
use warnings;

our $VERSION = '0.000119';

use Carp qw/croak/;

use File::ShareDir();

use Test2::Harness::Util qw/mod2file/;

use Importer Importer => 'import';

our @EXPORT = qw/share_dir share_file qdb_driver dbd_driver config_from_settings find_job format_duration parse_duration is_invalid_subtest_name/;

my %SCHEMA_TO_QDB_DRIVER = (
    mariadb => 'MySQL',
    mysql => 'MySQL',
    postgresql => 'PostgreSQL',
);

my %SCHEMA_TO_DBD_DRIVER = (
    mariadb    => 'DBD::MariaDB',
    mysql      => 'DBD::mysql',
    postgresql => 'DBD::postgresql',
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

sub find_job {
    my ($schema, $uuid, $try) = @_;

    my $jobs = $schema->resultset('Job');

    if (length $try) {
        return $jobs->search({job_id => $uuid}, {order_by => {'-desc' => 'job_try'}, limit => 1})->first
            if $try == -1;

        return $jobs->search({job_id => $uuid, job_try => $try})->first;
    }

    return $jobs->search({job_key => $uuid})->first
        || $jobs->search({job_id  => $uuid}, {order_by => {'-desc' => 'job_try'}, limit => 1})->first;
}

sub base_name {
    my ($in) = @_;

    my $out = lc($in);
    $out =~ s/\.sql$//;
    $out =~ s/\d+$//g;

    return $out;
}

sub qdb_driver {
    my $base = base_name(@_);
    return $SCHEMA_TO_QDB_DRIVER{$base};
}

sub dbd_driver {
    my $base = base_name(@_);
    return $SCHEMA_TO_DBD_DRIVER{$base};
}

sub share_file {
    my ($file) = @_;

    return File::ShareDir::dist_file('Test2-Harness-UI' => $file)
        unless 'dev' eq ($ENV{T2_HARNESS_UI_ENV} || '');

    my $path = "share/$file";
    croak "Could not find '$file'" unless -e $path;

    return $path;
}

sub share_dir {
    my ($dir) = @_;

    my $path;

    if ('dev' eq ($ENV{T2_HARNESS_UI_ENV} || '')) {
        $path = "share/$dir";
    }
    else {
        my $root = File::ShareDir::dist_dir('Test2-Harness-UI');
        $path = "$root/$dir";
    }

    croak "Could not find '$dir'" unless -d $path;

    return $path;
}

sub config_from_settings {
    my ($settings) = @_;

    my $db = $settings->prefix('yathui-db') or die "No DB settings";

    if (my $cmod = $db->config) {
        my $file = mod2file($cmod);
        require $file;

        return $cmod->yath_ui_config(%$$db);
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

    require Test2::Harness::UI::Config;
    return Test2::Harness::UI::Config->new(
        dbi_dsn  => $dsn,
        dbi_user => $db->user // '',
        dbi_pass => $db->pass // '',
    );
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

Test2::Harness::UI::Util - General Utilities

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

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
