package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '0.001100';

use File::Spec;

use Cwd qw/realpath/;
use Carp qw/croak/;
use File::Basename qw/dirname/;
use Time::HiRes;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    find_yath
    find_pfile
    PFILE_NAME
    find_in_updir
    is_generated_test_pl
    find_libraries
    mod2file
    show_bench
    strip_arisdottle
    fit_to_width
    clean_path
};

sub clean_path {
    my $path = shift;
    return realpath($path) // File::Spec->rel2abs($path);
}

sub mod2file {
    my ($mod) = @_;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

sub find_yath { clean_path(_find_yath()) }

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
    return clean_path($path) if -f $path;

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

sub find_libraries {
    my ($search, @paths) = @_;
    my @parts = grep $_, split /::(\*)?/, $search;

    @paths = @INC unless @paths;

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

sub show_bench {
    my ($start) = @_;

    require Test2::Util::Times;
    my $end = Time::HiRes::time();
    my $bench = Test2::Util::Times::render_bench($start, $end, times);

    print "\n$bench\n\n";
}

sub strip_arisdottle {
    my ($args) = @_;

    my @pass;
    for (my $i = 0; $i < @$args; $i++) {
        next unless $args->[$i] && $args->[$i] eq '::';
        (undef, @pass) = splice(@$args, $i);
        last;
    }

    return \@pass;
}

sub fit_to_width {
    my ($width, $join, $text) = @_;

    my @parts = ref($text) ? @$text : split /\s+/, $text;

    my @out;

    my $line = "";
    for my $part (@parts) {
        my $new = $line ? "$line$join$part" : $part;

        if ($line && length($new) > $width) {
            push @out => $line;
            $line = $part;
        }
        else {
            $line = $new;
        }
    }
    push @out => $line if $line;

    return join "\n" => @out;
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
