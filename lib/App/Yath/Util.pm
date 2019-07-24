package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '0.001080';

use File::Spec;

use Cwd qw/realpath/;
use Carp qw/croak/;
use File::Basename qw/dirname/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    find_yath
    find_pfile
    PFILE_NAME
    find_in_updir
    read_config
    is_generated_test_pl
};

sub find_yath { File::Spec->rel2abs(_find_yath()) }

sub _find_yath {
    return $App::Yath::SCRIPT if $App::Yath::SCRIPT;
    return $ENV{YATH_SCRIPT} if $ENV{YATH_SCRIPT};
    return $0 if $0 && $0 =~ m{yath$} && -f $0;

    require IPC::Cmd;
    if(my $out = IPC::Cmd::can_run('yath')) {
        return $out;
    }

    die "Could not find 'yath' in execution path";
}

sub find_in_updir {
    my $path = shift;
    return File::Spec->rel2abs($path) if -f $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { realpath(File::Spec->rel2abs($path)) };
        last unless $check;
        last if $seen{$check}++;
        return $check if -f $check;
    }

    return;
}

sub PFILE_NAME() { '.yath-persist.json' }

sub find_pfile {
    #If we find the file where YATH_PERSISTENCE_DIR is specified, return that path
    #Otherwise search for the file further
    if (my $base = $ENV{YATH_PERSISTENCE_DIR}){
        if (my $path = find_in_updir(File::Spec->catdir($base,PFILE_NAME()))){
            return $path;
        }
    }
    return find_in_updir(PFILE_NAME());
}

sub read_config {
    my ($cmd, %params) = @_;

    my $rcfile = $params{file} or croak "'file' is a required argument";

    if ($params{search}) {
        $rcfile = find_in_updir($rcfile) or return;
    }

    open(my $fh, '<', $rcfile) or croak "Could not open '$rcfile': $!";

    my $base = dirname(File::Spec->rel2abs($rcfile));

    my @out;

    my $in_cmd = 0;
    while (my $line = <$fh>) {
        chomp($line);
        if ($line =~ m/^\[(.*)\]$/) {
            $in_cmd = $1 eq $cmd;
            next;
        }
        next unless $in_cmd;

        $line =~ s/;.*$//g;
        $line =~ s/^\s*//g;
        $line =~ s/\s*$//g;
        my ($key, $val) = split /\s+/, $line, 2;
        if ($val && $val =~ s/^rel\(//) {
            die "Syntax error in $rcfile line $.: Expected ')'\n" unless $val =~ s/\)$//;
            $val = File::Spec->catfile($base, $val);
        }
        push @out => $key if defined $key;
        push @out => $val if defined $val;
    }

    return @out;
}

sub is_generated_test_pl {
    my ($file) = @_;

    open(my $fh, '<', $file) or die "Could not open '$file': $!";

    my $count = 0;
    while (my $line = <$fh>) {
        last if $count++ > 5;
        next unless $line =~ m/^# THIS IS A GENERATED YATH RUNNER TEST$/;
        return 1;
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Util - Common utils for yath.

=head1 DESCRIPTION

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
