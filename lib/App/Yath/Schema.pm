package App::Yath::Schema;
use utf8;
use strict;
use warnings;
use Carp qw/confess/;

our $VERSION = '2.000005';

use base 'DBIx::Class::Schema';

use Test2::Util::UUID qw/uuid2bin bin2uuid/;

confess "You must first load a App::Yath::Schema::NAME module"
    unless $App::Yath::Schema::LOADED;

#FIXME Do we need this?
#if ($App::Yath::Schema::LOADED =~ m/(MySQL|Percona|MariaDB)/i && eval { require DBIx::Class::Storage::DBI::mysql::Retryable; 1 }) {
#    __PACKAGE__->storage_type('::DBI::mysql::Retryable');
#}

require App::Yath::Schema::ResultSet;
__PACKAGE__->load_namespaces(
    default_resultset_class => 'ResultSet',
);

sub is_mysql {
    return 1 if is_mariadb();
    return 1 if is_percona();
    return 1 if $App::Yath::Schema::LOADED =~ m/MySQL/;
    return 0;
}

sub is_postgresql {
    return 1 if $App::Yath::Schema::LOADED =~ m/PostgreSQL/;
    return 0;
}

sub is_sqlite {
    return 1 if $App::Yath::Schema::LOADED =~ m/SQLite/;
    return 0;
}

sub is_percona {
    return 1 if $App::Yath::Schema::LOADED =~ m/Percona/;
    return 0;
}

sub is_mariadb {
    return 1 if $App::Yath::Schema::LOADED =~ m/MariaDB/;
    return 0;
}

sub format_uuid_for_db {
    my $class = shift;
    my ($uuid) = @_;

    return $uuid unless is_percona();
    return uuid2bin($uuid);
}

sub format_uuid_for_app {
    my $class = shift;
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

App::Yath::Schema - Yath database root schema object.

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT

