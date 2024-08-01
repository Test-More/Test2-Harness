package App::Yath::Schema::Overlay::Project;
our $VERSION = '2.000003';

package
    App::Yath::Schema::Result::Project;
use utf8;
use strict;
use warnings;

use Statistics::Basic qw/median/;


use Carp qw/confess/;
confess "You must first load a App::Yath::Schema::NAME module"
    unless $App::Yath::Schema::LOADED;

sub last_covered_run {
    my $self = shift;
    my %params = @_;

    my $query = {
        status => 'complete',
        project_id => $self->project_id,
        has_coverage => 1,
    };

    my $attrs = {
        order_by => {'-desc' => 'run_id'},
        rows => 1,
    };

    my $schema = $self->result_source->schema;

    if (my $username = $params{user}) {
        my $user = $schema->resultset('User')->find({username => $username}) or die "Invalid user: $username";
        $query->{'user_id'} = $user->user_id;
    }

    my $run = $schema->resultset('Run')->find($query, $attrs);
    return $run;
}

sub durations {
    my $self   = shift;
    my %params = @_;

    my $username = $params{user};
    my $limit    = $params{limit};

    my $schema = $self->result_source->schema;
    my $dbh = $schema->storage->dbh;

    my $query = <<"    EOT";
        SELECT test_files.filename, job_tries.duration
          FROM job_tries
          JOIN jobs USING(job_id)
          JOIN runs USING(run_id)
          JOIN test_files USING(test_file_id)
          JOIN users USING(user_id)
         WHERE runs.project_id = ?
           AND job_tries.duration IS NOT NULL
           AND test_files.filename IS NOT NULL
    EOT
    my @vals = ($self->project_id);

    my ($user_append, @user_args) = $username ? ("users.username = ?", $username) : ();

    if ($username) {
        $query .= "AND $user_append\n";
        push @vals => @user_args;
    }

    if ($limit) {
        my $where = $username ? "WHERE $user_append" : "";
        my $sth   = $dbh->prepare(<<"        EOT");
            SELECT run_id
              FROM runs
              JOIN users USING(user_id)
              $where
             ORDER BY run_id DESC
             LIMIT ?
        EOT

        $sth->execute(@user_args, $limit) or die $sth->errstr;

        my @ids = map { $_->[0] } @{$sth->fetchall_arrayref};

        if (@ids) {
            $query .= "AND run_id IN (" . join(',', map { '?' } @ids) . ")";
            push @vals => (@ids);
        }
    }

    my $sth = $dbh->prepare($query);
    $sth->execute(@vals) or die $sth->errstr;
    my $rows = $sth->fetchall_arrayref;

    my $data = {};
    for my $row (@$rows) {
        my ($file, $time) = @$row;
        push @{$data->{$file}} => $time;
    }

    for my $file (keys %$data) {
        my $set  = delete $data->{$file} or next;
        my $time = median($set);
        $data->{$file} = median($set);
    }

    my $sorted = [sort { $data->{$b} <=> $data->{$a} } keys %$data];
    $data = {lookup => $data, sorted => $sorted};

    return $data;
}

1;
__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Overlay::Project - Overlay for Project result class.

=head1 DESCRIPTION

This is where custom (not autogenerated) code for the Project result class lives.

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
