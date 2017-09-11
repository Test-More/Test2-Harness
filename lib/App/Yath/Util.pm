package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '0.001007';

use File::Spec;

use Carp qw/confess/;
use Cwd qw/realpath/;

use Test2::Harness::Util qw/open_file/;

use Importer Importer => 'import';

our @EXPORT_OK = qw/load_command find_yath find_pfile PFILE_NAME find_in_updir read_config/;

sub load_command {
    my ($cmd_name) = @_;
    my $cmd_class  = "App::Yath::Command::$cmd_name";
    my $cmd_file   = "App/Yath/Command/$cmd_name.pm";

    if (!eval { require $cmd_file; 1 }) {
        my $load_error = $@ || 'unknown error';

        confess "yath command '$cmd_name' not found. (did you forget to install $cmd_class?)"
            if $load_error =~ m{Can't locate \Q$cmd_file in \@INC\E};

        die $load_error;
    }

    return $cmd_class;
}

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
        my $check = realpath(File::Spec->rel2abs($path));
        last if $seen{$check}++;
        return $check if -f $check;
    }

    return;
}

sub PFILE_NAME() { '.yath-persist.json' }

sub find_pfile {
    return find_in_updir(PFILE_NAME());
}

sub read_config {
    my ($cmd) = @_;

    my $rcfile = find_in_updir('.yath.rc') or return;

    my $fh = open_file($rcfile, '<');

    my @out;

    my $in_cmd = 0;
    while (my $line = <$fh>) {
        chomp($line);
        if ($line =~ m/^\[(.*)\]$/) {
            $in_cmd = 1 if $1 eq $cmd;
            next;
        }
        next unless $in_cmd;

        $line =~ s/;.*$//g;
        $line =~ s/^\s*//g;
        $line =~ s/\s*$//g;
        push @out => split /\s+/, $line, 2;
    }

    return @out;
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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
