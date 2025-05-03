package App::Yath::ConfigFile;
use strict;
use warnings;

our $VERSION = '2.000005';

use File::Spec;

use Carp qw/croak/;
use Test2::Harness::Util qw/clean_path/;

use Test2::Harness::Util::HashBase qw{
    <file
    +global
    +command
};

sub init {
    my $self = shift;

    my $file = clean_path($self->{+FILE}) or croak "'file' is a required attribute";

    my ($v, $p) = File::Spec->splitpath($file);
    my $rel = File::Spec->catpath($v, $p);

    open(my $fh, '<', $file) or die "Cannot open config file '$file': $!";

    my ($global, $command) = ([], {});

    my $set = $global;

    while (my $line = <$fh>) {
        chomp($line);
        $line =~ s/\s*(;|#).*//g;
        $line =~ s/^\s+//g;
        $line =~ s/\s+$//g;
        next unless length($line);

        # Support rel(...)
        # Also support legacy glob(...) and relglob(...) by stripping the glob
        # part out as that is handled automatically now in applicable options.
        $line =~ s{rel(?:glob)?\(([^\)]+)\)}{clean_path("$rel/$1")}ge;
        $line =~ s{glob\(([^\)]+)\)}{$1}g;

        if ($line =~ m/^\[(\S+)\]/) {
            $set = $command->{$1} //= [];
            next;
        }

        # --foo and --foo=bar
        if ($line =~ m/^--?\S+(?:=.+)?$/) {
            push @$set => $line;
            next;
        }

        # --foo bar and -f bar
        if ($line =~ m/^(--?\S+)\s+(\S.*)/) {
            push @$set => ($1, $2);
            next;
        }

        die "Syntax error in config file $file at line $.: $line.\n";
    }

    close($fh);

    $self->{+GLOBAL} = $global;
    $self->{+COMMAND} = $command;
}

sub global { @{$_[0]->{+GLOBAL} // []} }

sub command { @{$_[0]->{+COMMAND}->{$_[1]} // []} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::ConfigFile - FIXME

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

