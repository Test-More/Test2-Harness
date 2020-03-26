package Test2::Harness::UI::CPANImporter;
use strict;
use warnings;

our $VERSION = '0.000028';

use Carp qw/croak/;

use HTTP::Tiny;
use File::Temp qw/tempdir/;
use IO::Uncompress::Gunzip qw/gunzip/;

use Test2::Harness::UI::Util::HashBase qw/-config -dir/;

sub init {
    my $self = shift;

    croak "'config' is a required attribute"
        unless $self->{+CONFIG};

    my $dir = tempdir();
    $self->{+DIR} = $dir;
}

sub run {
    my $self = shift;

    my $batch = int(time);

    my $schema = $self->{+CONFIG}->schema;
    my $details = $self->download('02packages.details.txt');
    my $perms   = $self->download('06perms.txt');

    my $mod_pkg_map = {};
    open(my $dfh, '<', $details) or die "Could not open $details for reading: $!";
    my $header = 1;
    while(my $line = <$dfh>) {
        chomp($line);
        next if $header && $line;
        $header = 0;
        next unless $line;

        my ($mod, $ver, $pkg) = split /\s+/, $line;
        $pkg =~ s{^.*/}{}g;
        $pkg =~ s{-[^A-Za-z_].*$}{}g;

        $mod_pkg_map->{$mod} = $pkg;
    }
    close($dfh);

    open(my $pfh, '<', $perms) or die "Could not open $perms for reading: $!";
    $header = 1;
    while(my $line = <$pfh>) {
        chomp($line);
        next if $header && $line;
        $header = 0;

        my ($mod, $id) = split /,/, $line;

        if (my $email = $schema->resultset('Email')->find({local => $id, domain => 'cpan.org'})) {
            next unless $email->verified;
            my $user = $email->user;

            my $project_name = $mod_pkg_map->{$mod} or next;
            my $project = $schema->resultset('Project')->find_or_create({name => $project_name});

            $schema->resultset('Permission')->update_or_create({
                project_id => $project->project_id,
                user_id => $user->user_id,
                updated => \'NOW()',
                cpan_batch => $batch,
            }) or die "Could not add permissions for $id on $project";
        }
    }
    close($dfh);

    my $dbh = $self->{+CONFIG}->connect;
    my $sth = $dbh->prepare('DELETE FROM permissions WHERE cpan_batch IS NOT NULL AND cpan_batch != ?');
    $sth->execute($batch) or die $sth->errstr;
}

sub download {
    my $self = shift;
    my ($file) = @_;

    my $path = $self->{+DIR} . '/' . $file;

    my $resp = HTTP::Tiny->new->get("http://www.cpan.org/modules/${file}.gz");
    die "Could not download ${file}.gz" unless $resp->{success};
    open(my $fh, '>', $path) or die "Could not open $path for writing: $!";
    gunzip(\($resp->{content}) => $fh);
    close($fh);

    return $path;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::CPANImporter - Import permissions from CPAN

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
