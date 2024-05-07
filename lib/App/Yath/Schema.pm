package App::Yath::Schema;
use utf8;
use strict;
use warnings;
use Carp qw/confess/;

use App::Yath::Schema::UUID qw/uuid_inflate/;

use Test2::Harness::Util::UUID qw/gen_uuid/;

our $VERSION = '2.000000';

use base 'DBIx::Class::Schema';

confess "You must first load a App::Yath::Schema::NAME module"
    unless $App::Yath::Schema::LOADED;

#if ($App::Yath::Schema::LOADED =~ m/(MySQL|Percona|MariaDB)/i && eval { require DBIx::Class::Storage::DBI::mysql::Retryable; 1 }) {
#    __PACKAGE__->storage_type('::DBI::mysql::Retryable');
#}

require App::Yath::Schema::ResultSet;
__PACKAGE__->load_namespaces(
    default_resultset_class => 'ResultSet',
);

sub config {
    my $self = shift;
    my ($setting, @val) = @_;

    my $conf = $self->resultset('Config')->find_or_create({config_id => gen_uuid(), setting => $setting, @val ? (value => $val[0]) : ()});

    $conf->update({value => $val[0]}) if @val;

    return $conf->value;
}

sub vague_run_search {
    my $self = shift;
    my (%params) = @_;

    my ($project, $run, $user);

    my $query = $params{query} // {status => 'complete'};
    my $attrs = $params{attrs} // {order_by => {'-desc' => 'run_ord'}, rows => 1};

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
        my $uuid = uuid_inflate($source);

        if ($uuid) {
            $run = $self->resultset('Run')->find({%$query, run_id => $uuid}, $attrs);
            return $run if $run;
        }

        if (my $p = $self->resultset('Project')->find($uuid ? {project_id => $uuid} : {name => $source})) {
            die "Project mismatch ($source)"
                if $project && $project->project_id ne $p->project_id;

            $query->{project_id} = $p->project_id;
        }
        elsif (my $u = $self->resultset('User')->find($uuid ? {user_id => $uuid} : {username => $source})) {
            die "User mismatch ($source)"
                if $user && $user->user_id ne $u->user_id;

            $query->{user_id} = $u->user_id;
        }
        else {
            die "No UUID match in runs, users, or projects ($uuid)" if $uuid;
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
