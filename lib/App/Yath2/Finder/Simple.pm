package App::Yath2::Finder::Simple;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();

use App::Yath2::TestFile;

# Discover test files from a list of positional arguments. Each arg is
# either a single file path or a directory to scan recursively. Returns
# a list of App::Yath2::TestFile objects, one per discovered file.
#
# No finder options yet: the scan matches *.t files (case-insensitive
# on the extension). Symlinks are followed but a seen-path guard keeps
# us out of infinite loops. Non-existent paths croak; a file argument
# with a non-.t extension is accepted verbatim (so users can run, e.g.,
# t/my_test.pl).
sub find {
    my ($class, @paths) = @_;

    croak "no paths to search" unless @paths;

    my %seen;
    my @files;

    for my $path (@paths) {
        croak "'$path' does not exist" unless -e $path;

        if (-d $path) {
            _scan_dir($path, \%seen, \@files);
        }
        else {
            my $abs = File::Spec->rel2abs($path);
            next if $seen{$abs}++;
            push @files => $abs;
        }
    }

    return map { App::Yath2::TestFile->new(file => $_) } @files;
}

sub _scan_dir {
    my ($dir, $seen, $files) = @_;

    my $abs = File::Spec->rel2abs($dir);
    return if $seen->{"DIR:$abs"}++;

    opendir(my $dh, $dir) or croak "Could not opendir '$dir': $!";
    my @entries = sort grep { !/^\./ } readdir($dh);
    closedir($dh);

    for my $entry (@entries) {
        my $child = File::Spec->catfile($dir, $entry);
        if (-d $child) {
            _scan_dir($child, $seen, $files);
        }
        elsif (-f $child && $child =~ /\.t$/i) {
            my $child_abs = File::Spec->rel2abs($child);
            next if $seen->{$child_abs}++;
            push @{$files} => $child_abs;
        }
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Finder::Simple - Minimal positional-arg test discovery.

=head1 DESCRIPTION

Turns a list of filesystem paths (files or directories) into a list of
L<App::Yath2::TestFile> objects. Used by
L<App::Yath2::Command::test> in Stage 5 before the real finder/plugin
layer exists; expect this module to be superseded (or extended) by a
plugin-driven finder in later stages.

=head1 SYNOPSIS

    use App::Yath2::Finder::Simple;

    my @tests = App::Yath2::Finder::Simple->find('t/foo.t', 't/bar');

=head1 METHODS

=over 4

=item @tests = $class->find(@paths)

Scan C<@paths>. Files are accepted verbatim (any extension);
directories are recursively scanned for C<*.t> files (case-
insensitive). Duplicate absolute paths are dropped. Non-existent
paths croak.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
