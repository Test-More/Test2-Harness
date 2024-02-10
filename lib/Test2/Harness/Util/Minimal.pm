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
require File::Spec;
require Cwd;

our @EXPORT = qw/clean_path find_in_updir pre_process_args scan_config/;

# Custom import that generates new exports that goto the functions defined in
# this class. This way if this module gets reloaded we do not have old copies
# of these subs running around.
sub import {
    my $class = shift;
    my @caller = caller;

    for my $sub (@_) {
        no strict 'refs';

        die "$class does not export '$sub' at $caller[1] line $caller[2].\n" unless $class->can($sub);

        # Die if we are going to redefine a subroutine that we did not originally put in place
        if (my $oldref = $caller[0]->can($sub)) {
            require B;
            my $cobj = B::svref_2object($oldref);
            my $pkg  = $cobj->GV->STASH->NAME;
            die "Attempt to import $class\::$sub which would override existing $caller[0]\::$sub at $caller[1] line $caller[2].\n" unless $pkg eq $class;
        }

        no warnings 'redefine';
        *{"$caller[0]\::$sub"} = sub {
            my @caller2 = caller;
            my $ref = $class->can($sub) or die "$class no longer has a $sub() subroutine to call at $caller2[1] line $caller2[2] (Originally imported at $caller[1] line $caller[2]).\n";
            goto &$ref;
        };
    }
}

$Test2::Harness::Util::Minimal::RELOAD //= 0;
sub RELOAD {
    my $stash = do { no strict 'refs'; \%{__PACKAGE__ . "::"} };
    delete $stash->{$_} for (@EXPORT, qw/RELOAD VERSION ISA EXPORT import/);
    delete $INC{'Test2/Harness/Util/Minimal.pm'};
    require Test2::Harness::Util::Minimal;
    return $Test2::Harness::Util::Minimal::RELOAD += 1;
}

sub clean_path {
    my ( $path, $absolute ) = @_;

    $absolute //= 1;
    $path = Cwd::realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
}

sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -f $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { Cwd::realpath(File::Spec->rel2abs($path)) };
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
