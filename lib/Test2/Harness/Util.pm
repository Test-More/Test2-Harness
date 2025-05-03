package Test2::Harness::Util;
use strict;
use warnings;

use Cwd qw/realpath/;
use Carp qw/confess croak/;
use Fcntl qw/LOCK_EX LOCK_UN :mode/;
use Test2::Util qw/try_sig_mask do_rename/;

use File::Spec;

our $VERSION = '2.000005';

use Importer Importer => 'import';

use Importer 'Test2::Util::Times' => qw/render_duration/;

our @EXPORT_OK = (
    qw{
        find_libraries
        mod2file
        file2mod
        fqmod
        parse_exit
        hub_truth
        apply_encoding
        chmod_tmp

        maybe_open_file
        maybe_read_file
        open_file
        read_file
        write_file
        write_file_atomic
        lock_file
        unlock_file

        hash_purge

        is_same_file

        render_status_data

        clean_path
        find_in_updir
    },
);

sub clean_path {
    my ( $path, $absolute ) = @_;

    confess "No path was provided to clean_path()" unless $path;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
}

sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -e $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { realpath(File::Spec->rel2abs($path)) };
        last unless $check;
        last if $seen{$check}++;
        return $check if -e $check;
    }

    return;
}

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

sub hash_purge {
    my ($hash) = @_;

    my $keep = 0;

    for my $key (keys %$hash) {
        my $val = $hash->{$key};

        my $delete = 0;
        $delete = 1 unless defined($val);
        $delete ||= ref($hash->{$key}) eq 'HASH' && !hash_purge($hash->{$key});

        if ($delete) {
            delete $hash->{$key};
            next;
        }

        $keep++;
    }

    return $keep;
}

sub chmod_tmp {
    my $file = shift;

    my $mode = S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO;

    chmod($mode, $file);
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
    croak "an exit value is required" unless defined $exit;

    my $sig = $exit & 127;
    my $dmp = $exit & 128;

    return {
        sig => $sig,
        err => ($exit >> 8),
        dmp => $dmp,
        all => $exit,
    };
}

sub hub_truth {
    my ($f) = @_;

    return $f->{hubs}->[0] if $f->{hubs} && @{$f->{hubs}};
    return $f->{trace} if $f->{trace};
    return {};
}

sub fqmod {
    my ($input, $prefixes, %options) = @_;

    croak "At least 1 prefix is required" unless $prefixes;

    $prefixes = [$prefixes] unless ref($prefixes) eq 'ARRAY';

    croak "At least 1 prefix is required" unless @$prefixes;
    croak "Cannot use no_require when providing multiple prefixes" if $options{no_require} && @$prefixes > 1;

    if ($input =~ m/^\+(.*)$/) {
        my $mod = $1;
        return $mod if $options{no_require};
        return $mod if eval { require(mod2file($mod)); 1 };
        confess($@);
    }

    my %tried;
    for my $pre (@$prefixes) {
        my $mod = $input =~ m/^\Q$pre\E/ ? $input : "$pre\::$input";

        if ($options{no_require}) {
            return $mod;
        }
        else {
            return $mod if eval { require(mod2file($mod)); 1 };
            ($tried{$mod}) = split /\n/, $@;
            $tried{$mod} =~ s{^(Can't locate \S+ in \@INC).*$}{$1.};
        }
    }

    my @caller = caller;

    die "Could not locate a module matching '$input' at $caller[1] line $caller[2], the following were checked:\n" . join("\n", map { " * $_: $tried{$_}" } sort keys %tried) . "\n";
}

sub file2mod {
    my $file = shift;
    my $mod  = $file;
    $mod =~ s{/}{::}g;
    $mod =~ s/\..*$//;
    return $mod;
}

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
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

sub render_status_data {
    my ($data) = @_;
    croak "must pass in a data array or undef" unless @_;

    return unless @$data;

    my $out = "";

    for my $group (@$data) {
        my $gout = "\n";
        $gout .= "**** $group->{title} ****\n\n" if defined $group->{title};

        for my $table (@{$group->{tables} || []}) {
            my $rows = $table->{rows};

            if (my $format = $table->{format}) {
                my $rows2 = [];

                for my $row (@$rows) {
                    my $row2 = [];
                    for (my $i = 0; $i < @$row; $i++) {
                        my $val = $row->[$i];
                        my $fmt = $format->[$i];

                        $val = defined($val) ? render_duration($val) : '--'
                            if $fmt && $fmt eq 'duration';

                        push @$row2 => $val;
                    }
                    push @$rows2 => $row2;
                }

                $rows = $rows2;
            }

            next unless $rows && @$rows;

            my $tt = Term::Table->new(
                header => $table->{header},
                rows   => $rows,

                sanitize     => 1,
                collapse     => 1,
                auto_columns => 1,

                %{$table->{term_table_opts} || {}},
            );

            $gout .= "** $table->{title} **\n" if defined $table->{title};
            $gout .= "$_\n" for $tt->render;
            $gout .= "\n";
        }

        if ($group->{lines} && @{$group->{lines}}) {
            $gout .= "$_\n" for @{$group->{lines}};
            $gout .= "\n";
        }

        $out .= $gout;
    }

    return $out;
}



1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util - FIXME

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

