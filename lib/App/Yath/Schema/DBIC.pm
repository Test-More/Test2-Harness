package App::Yath::Schema::DBIC;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use base 'DBIx::Class::Schema';

use Carp qw/confess/;
use Exporter 'import';

use Test2::Util::UUID qw/uuid2bin bin2uuid/;

our @EXPORT_OK = qw/
    is_sqlite
    is_postgresql
    is_mysql
    is_mariadb
    is_percona
    can_store_null_character
    format_uuid_for_db
    format_uuid_for_app
/;

if ($App::Yath::Schema::DBIC::LOADED) {
    require App::Yath::Schema::DBIC::ResultSet;
    __PACKAGE__->load_namespaces(
        default_resultset_class => '+App::Yath::Schema::DBIC::ResultSet',
    );
}

sub is_sqlite     { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/SQLite/     ? 1 : 0 }
sub is_postgresql { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/PostgreSQL/ ? 1 : 0 }
sub is_mariadb    { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/MariaDB/    ? 1 : 0 }
sub is_percona    { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/Percona/    ? 1 : 0 }

sub is_mysql {
    return 1 if is_mariadb();
    return 1 if is_percona();
    return 1 if ($App::Yath::Schema::DBIC::LOADED // '') =~ m/MySQL/;
    return 0;
}

sub can_store_null_character {
    return 0 if is_postgresql();
    return 1;
}

sub format_uuid_for_db {
    shift if @_ && defined $_[0] && !ref($_[0]) && $_[0] eq __PACKAGE__;
    my ($uuid) = @_;
    return $uuid unless is_percona();
    return uuid2bin($uuid);
}

sub format_uuid_for_app {
    shift if @_ && defined $_[0] && !ref($_[0]) && $_[0] eq __PACKAGE__;
    my ($uuid_bin) = @_;
    return $uuid_bin unless is_percona();
    return bin2uuid($uuid_bin);
}

sub config {
    my $self = shift;
    my ($setting, @val) = @_;

    my $conf = $self->resultset('Config')->find_or_create({setting => $setting, @val ? (value => $val[0]) : (value => 0)});

    $conf->update({value => $val[0]}) if @val;

    return $conf->value;
}

sub vague_run_search {
    my $self = shift;
    my (%params) = @_;

    my ($project, $run, $user);

    my $query = $params{query} // {status => 'complete'};
    my $attrs = $params{attrs} // {order_by => {'-desc' => 'run_id'}, rows => 1};

    $attrs->{offset} = $params{idx} if $params{idx};

    if (my $username = $params{username}) {
        $user = $self->resultset('User')->find({username => $username}) || die "Invalid Username ($username)";
        $query->{user_id} = $user->user_id;
    }

    if (my $project_name = $params{project_name}) {
        $project = $self->resultset('Project')->find({name => $project_name}) || die "Invalid Project ($project)";
        $query->{project_id} = $project->project_id;
    }

    if (my $source = $params{source}) {
        my $run = $self->resultset('Run')->find_by_id_or_uuid($source, $query, $attrs);
        return $run if $run;

        if (my $p = $self->resultset('Project')->find({name => $source})) {
            die "Project mismatch ($source)"
                if $project && $project->project_id ne $p->project_id;

            $query->{project_id} = $p->project_id;
        }
        elsif (my $u = $self->resultset('User')->find({username => $source})) {
            die "User mismatch ($source)"
                if $user && $user->user_id ne $u->user_id;

            $query->{user_id} = $u->user_id;
        }
        else {
            die "No match for source ($source)";
        }
    }

    return $self->resultset('Run')->search($query, $attrs)
        if $params{list};

    $run = $self->resultset('Run')->find($query, $attrs);
    return $run;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC - Unified DBIx::Class schema class with per-backend helpers.

=cut
