package Test2::Harness::UI::Schema;
use utf8;
use strict;
use warnings;
use Carp qw/confess/;

use Test2::Harness::Util qw/looks_like_uuid/;

our $VERSION = '0.000119';

use base 'DBIx::Class::Schema';

confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

require Test2::Harness::UI::Schema::ResultSet;
__PACKAGE__->load_namespaces(
    default_resultset_class => 'ResultSet',
);

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
        my $uuid = looks_like_uuid($source);

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
