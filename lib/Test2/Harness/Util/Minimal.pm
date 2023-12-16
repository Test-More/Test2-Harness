package Test2::Harness::Util::Minimal;
use strict;
use warnings;

our $VERSION = '2.000000';

###############################################################################
#                                                                             #
#                 !!!!!!!!   READ THIS FIRST    !!!!!!!!                      #
#                                                                             #
# This file needs to load as little as possible. This is used to process some #
# initial config files and arguments. These may add paths to @INC. Anything   #
# we load here will be loaded before the @INC changes!                        #
#                                                                             #
###############################################################################

# Core, not likely to be overriden in a project lib directory,
# and if they are, oh well, we need them.
use File::Spec;
use Cwd qw/realpath/;
BEGIN { require Exporter; push @Test2::Harness::Util::Minimal::ISA => 'Exporter' }

our @EXPORT = qw/clean_path find_in_updir pre_process_args scan_config/;

sub clean_path {
    my ( $path, $absolute ) = @_;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
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

sub scan_config {
    my ($file) = @_;

    my ($vol, $dir) = File::Spec->splitpath(clean_path($file));
    my $reldir = File::Spec->catpath($vol, $dir);

    my @out;

    open(my $fh, '<', $file) or die "Could not open config file '$file': $!";
    while (my $line = <$fh>) {
        chomp($line);

        # Only scan the global top section
        last if $line =~ /^\[/;

        next unless $line =~ m/^(-D|--dev-lib)(?:(=)?(.+))?$/;
        my ($arg, $eq, $val) = ($1, $2, $3);
        $eq //= '';

        if ($val =~ m/^(relglob|rel|glob)\((.+)\)$/) {
            my ($op, $v) = ($1, $2);
            $val = File::Spec->catfile($reldir, $v) if $op =~ m/rel/;

            if ($op =~ m/glob/) {
                push @out => map { "${arg}${eq}${_}" } glob($val);
                last;
            }
        }

        push @out => "${arg}${eq}${val}";
    }

    return \@out;
}

sub pre_process_args {
    my ($args) = @_;

    my $defaults = 0;
    my @add_paths;
    my $prefix;

    my @todo = @$args;
    while (my $arg = shift @todo) {
        if ($arg =~ m/^(?:-D|--dev-lib)(?:=?(.+))?$/) {
            if ($1) { push @add_paths => clean_path($1); next }
            next if $defaults++;
            push @add_paths => map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch';
        }
        elsif ($arg =~ m/^--procname_prefix(?:=(.+))?$/) {
            if   ($1) { $prefix = $1 }
            else      { $prefix = shift(@todo) }
        }
    }

    return {
        dev_libs => \@add_paths,
        prefix   => $prefix,
    };
}


1;
