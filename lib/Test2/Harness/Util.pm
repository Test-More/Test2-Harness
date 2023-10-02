package Test2::Harness::Util;
use strict;
use warnings;

use Carp qw/confess/;
use Cwd qw/realpath/;
use Test2::Util qw/try_sig_mask do_rename/;
use Fcntl qw/LOCK_EX LOCK_UN SEEK_SET :mode/;
use File::Spec;

our $VERSION = '1.000155';

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    find_libraries
    clean_path

    parse_exit
    mod2file
    file2mod
    fqmod

    maybe_open_file
    maybe_read_file
    open_file
    read_file
    write_file
    write_file_atomic
    lock_file
    unlock_file

    hub_truth

    apply_encoding

    process_includes

    chmod_tmp

    looks_like_uuid
    is_same_file
};

sub is_same_file {
    my ($file1, $file2) = @_;

    return 0 unless defined $file1;
    return 0 unless defined $file2;

    return 1 if "$file1" eq "$file2";
    return 1 if clean_path($file1) eq clean_path($file2);

    return 0 unless -e $file1;
    return 0 unless -e $file2;

    my ($dev1, $inode1) = stat($file1);
    my ($dev2, $inode2) = stat($file2);

    return 0 unless $dev1 == $dev2;
    return 0 unless $inode1 == $inode2;
    return 1;
}

sub looks_like_uuid {
    my ($in) = @_;

    return undef unless defined $in;
    return undef unless length($in) == 36;
    return undef unless $in =~ m/^[0-9A-F\-]+$/i;
    return $in;
}

sub chmod_tmp {
    my $file = shift;

    my $mode = S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO;

    chmod($mode, $file);
}

sub process_includes {
    my %params = @_;

    my @start = @{delete $params{list} // []};

    my @list;
    my %seen = ('.' => 1);

    if (my $ch_dir = delete $params{ch_dir}) {
        for my $path (@start) {
            # '.' is special.
            $seen{'.'}++ and next if $path eq '.';

            if (File::Spec->file_name_is_absolute($path)) {
                push @list => $path;
            }
            else {
                push @list => File::Spec->catdir($ch_dir, $path);
            }
        }
    }
    else {
        @list = @start;
    }

    push @list => @INC if delete $params{include_current};

    @list = map { $_ eq '.' ? $_ : clean_path($_) || $_ } @list if delete $params{clean};

    @list = grep { !$seen{$_}++ } @list;

    # If we ask for dot, or saw it during our processing, add it to the end.
    push @list => '.' if delete($params{include_dot}) || $seen{'.'} > 1;

    confess "Invalid parameters: " . join(', ' => sort keys %params) if keys %params;

    return @list;
}

sub apply_encoding {
    my ($fh, $enc) = @_;
    return unless $enc;

    # https://rt.perl.org/Public/Bug/Display.html?id=31923
    # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
    # order to avoid the thread segfault.
    return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
    binmode($fh, ":encoding($enc)");
}

sub parse_exit {
    my ($exit) = @_;

    my $sig = $exit & 127;
    my $dmp = $exit & 128;

    return {
        sig => $sig,
        err => ($exit >> 8),
        dmp => $dmp,
        all => $exit,
    };
}

sub fqmod {
    my ($prefix, $input) = @_;
    return $1 if $input =~ m/^\+(.*)$/;
    return "$prefix\::$input";
}

sub hub_truth {
    my ($f) = @_;

    return $f->{hubs}->[0] if $f->{hubs} && @{$f->{hubs}};
    return $f->{trace} if $f->{trace};
    return {};
}

sub maybe_read_file {
    my ($file) = @_;
    return undef unless -f $file;
    return read_file($file);
}

sub read_file {
    my ($file, @args) = @_;

    my $fh = open_file($file, '<', @args);
    local $/;
    my $out = <$fh>;
    close_file($fh, $file);

    return $out;
}

sub write_file {
    my ($file, @content) = @_;

    my $fh = open_file($file, '>');
    print $fh @content;
    close_file($fh, $file);

    return @content;
};

my %COMPRESSION = (
    bz2 => {module => 'IO::Uncompress::Bunzip2', errors => \$IO::Uncompress::Bunzip2::Bunzip2Error},
    gz  => {module => 'IO::Uncompress::Gunzip',  errors => \$IO::Uncompress::Gunzip::GunzipError},
);
sub open_file {
    my ($file, $mode, %opts) = @_;
    $mode ||= '<';

    unless ($opts{no_decompress}) {
        if (my $ext = $opts{ext}) {
            $opts{compression} //= $COMPRESSION{$ext} or die "Unknown compression: $ext";
        }

        if ($file =~ m/\.(gz|bz2)$/i) {
            my $ext = lc($1);
            $opts{compression} //= $COMPRESSION{$ext} or die "Unknown compression: $ext";
        }

        if ($mode eq '<' && $opts{compression}) {
            my $spec = $opts{compression};
            my $mod  = $spec->{module};
            require(mod2file($mod));

            my $fh = $mod->new($file) or die "Could not open file '$file' ($mode): ${$spec->{errors}}";
            return $fh;
        }
    }

    open(my $fh, $mode, $file) or confess "Could not open file '$file' ($mode): $!";
    return $fh;
}

sub maybe_open_file {
    my ($file, $mode) = @_;
    return undef unless -f $file;
    return open_file($file, $mode);
}

sub close_file {
    my ($fh, $name) = @_;
    return if close($fh);
    confess "Could not close file: $!" unless $name;
    confess "Could not close file '$name': $!";
}

sub write_file_atomic {
    my ($file, @content) = @_;

    my $pend = "$file.pend";

    my ($ok, $err) = try_sig_mask {
        write_file($pend, @content);
        my ($ren_ok, $ren_err) = do_rename($pend, $file);
        die "$pend -> $file: $ren_err" unless $ren_ok;
    };

    die $err unless $ok;

    return @content;
}

sub lock_file {
    my ($file, $mode) = @_;

    my $fh;
    if (ref $file) {
        $fh = $file;
    }
    else {
        open($fh, $mode // '>>', $file) or die "Could not open file '$file': $!";
    }

    for (1 .. 21) {
        flock($fh, LOCK_EX) and last;
        die "Could not lock file (try $_): $!" if $_ >= 20;
        next if $!{EINTR} || $!{ERESTART};
        die "Could not lock file: $!";
    }

    return $fh;
}

sub unlock_file {
    my ($fh) = @_;
    for (1 .. 21) {
        flock($fh, LOCK_UN) and last;
        die "Could not unlock file (try $_): $!" if $_ >= 20;
        next if $!{EINTR} || $!{ERESTART};
        die "Could not unlock file: $!";
    }

    return $fh;
}

sub clean_path {
    my ( $path, $absolute ) = @_;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
}

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

sub file2mod {
    my $file = shift;
    my $mod  = $file;
    $mod =~ s{/}{::}g;
    $mod =~ s/\..*$//;
    return $mod;
}


sub find_libraries {
    my ($search, @paths) = @_;
    my @parts = grep $_, split /::(\*)?/, $search;

    @paths = @INC unless @paths;

    @paths = map { File::Spec->canonpath($_) } @paths;

    my %prefixes = map {$_ => 1} @paths;

    my @found;
    my @bases = ([map { [$_ => length($_)] } @paths]);
    while (my $set = shift @bases) {
        my $new_base = [];
        my $part      = shift @parts;

        for my $base (@$set) {
            my ($dir, $prefix) = @$base;
            if ($part ne '*') {
                my $path = File::Spec->catdir($dir, $part);
                if (@parts) {
                    push @$new_base => [$path, $prefix] if -d $path;
                }
                elsif (-f "$path.pm") {
                    push @found => ["$path.pm", $prefix];
                }

                next;
            }

            opendir(my $dh, $dir) or next;
            for my $item (readdir($dh)) {
                next if $item =~ m/^\./;
                my $path = File::Spec->catdir($dir, $item);
                if (@parts) {
                    # Sometimes @INC dirs are nested in eachother.
                    next if $prefixes{$path};

                    push @$new_base => [$path, $prefix] if -d $path;
                    next;
                }

                next unless -f $path && $path =~ m/\.pm$/;
                push @found => [$path, $prefix];
            }
        }

        push @bases => $new_base if @$new_base;
    }

    my %out;
    for my $found (@found) {
        my ($path, $prefix) = @$found;

        my @file_parts = File::Spec->splitdir(substr($path, $prefix));
        shift @file_parts if $file_parts[0] eq '';

        my $file = join '/' => @file_parts;
        $file_parts[-1] = substr($file_parts[-1], 0, -3);
        my $module = join '::' => @file_parts;

        $out{$module} //= $file;
    }

    return \%out;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util - General utiliy functions.

=head1 DESCRIPTION

=head1 METHODS

=head2 MISC

=over 4

=item apply_encoding($fh, $enc)

Apply the specified encoding to the filehandle.

B<Justification>:
L<PERLBUG 31923|https://rt.perl.org/Public/Bug/Display.html?id=31923>
If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
order to avoid the thread segfault.

This is a reusable implementation of this:

    sub apply_encoding {
        my ($fh, $enc) = @_;
        return unless $enc;
        return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
        binmode($fh, ":encoding($enc)");
    }

=item $clean = clean_path($path)

Take a file path and clean it up to a minimal absolute path if possible. Always
returns a path, but if it cannot be cleaned up it is unchanged.

=item $hashref = find_libraries($search)

=item $hashref = find_libraries($search, @paths)

C<@INC> is used if no C<@paths> are provided.

C<$search> should be a module name with C<*> wildcards replacing sections.

    find_libraries('Foo::*::Baz')
    find_libraries('*::Bar::Baz')
    find_libraries('Foo::Bar::*')

These all look for modules matching the search, this is a good way to find
plugins, or similar patterns.

The result is a hashref of C<< { $module => $path } >>. If a module exists in
more than 1 search path the first is used.

=item $mod = fqmod($prefix, $mod)

This will automatically add C<$prefix> to C<$mod> with C<'::'> to join them. If
C<$mod> starts with the C<'+'> character the character will be removed and the
result returned without prepending C<$prefix>.

=item hub_truth

This is an internal implementation detail, do not use it.

=item $hashref = parse_exit($?)

This parses the exit value as typically stored in C<$?>.

Resulting hash:

    {
        sig => ($? & 127), # Signal value if the exit was caused by a signal
        err => ($? >> 8),  # Actual exit code, if any.
        dmp => ($? & 128), # Was there a core dump?
        all => $?,         # Original exit value, unchanged
    }


=item @list = process_includes(%PARAMS)

This method will build up a list of include dirs fit for C<@INC>. The returned
list should contain only unique values, in proper order.

Params:

=over 4

=item list => \@START

Paths to start the new list.

Optional.

=item ch_dir => $path

Prefix to prepend to all paths in the C<list> param. No effect without an
initial list.

=item include_current => $bool

This will add all paths from C<@INC> to the output, after the initial list.
Note that '.', if in C<@INC> will be moved to the end of the final output.

=item clean => $bool

If included all paths except C<'.'> will be cleaned using C<clean_path()>.

=item include_dot => $bool

If true C<'.'> will be appended to the end of the output.

B<Note> even if this is set to false C<'.'> may still be included if it was in
the initial list, or if it was in C<@INC> and C<@INC> was included using the
C<include_current> parameter.

=back

=back

=head2 FOR DEALING WITH MODULE <-> FILE CONVERSION

These convert between module names like C<Foo::Bar> and filenames like
C<Foo/Bar.pm>.

=over 4

=item $file = mod2file($mod)

=item $mod = file2mod($file)

=back

=head2 FOR READING/WRITING FILES

=over 4

=item $fh = open_file($path, $mode)

=item $fh = open_file($path)

If no mode is provided C<< '<' >> is assumed.

This will open the file at C<$path> and return a filehandle.

An exception will be thrown if the file cannot be opened.

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item $text = read_file($file)

This will open the file at C<$path> and return all its contents.

An exception will be thrown if the file cannot be opened.

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item $fh = maybe_open_file($path)

=item $fh = maybe_open_file($path, $mode)

If no mode is provided C<< '<' >> is assumed.

This will open the file at C<$path> and return a filehandle.

C<undef> is returned if the file cannot be opened.

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item $text = maybe_read_file($path)

This will open the file at C<$path> and return all its contents.

This will return C<undef> if the file cannot be opened.

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item @content = write_file($path, @content)

Write content to the specified file. This will open the file with mode
C<< '>' >>, write the content, then close the file.

An exception will be thrown if any part fails.

=item @content = write_file_atomic($path, @content)

This will open a temporary file, write the content, close the file, then rename
the file to the desired C<$path>. This is essentially an atomic write in that
C<$file> will not exist until all content is written, preventing other
processes from doing a partial read while C<@content> is being written.

=back

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
