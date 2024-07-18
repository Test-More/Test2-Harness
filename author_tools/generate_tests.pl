#!/usr/bin/env perl
use strict;
use warnings;

use File::Find qw/find/;
use File::Path qw/make_path/;
use Capture::Tiny qw/capture/;

my %have_stubs;
my %need_stubs;
my %have_pkg;

find({no_chdir => 1, wanted => \&is_stub}, 't');
find({no_chdir => 1, wanted => \&need_stub}, 'lib');

sub is_stub {
    my $file = $File::Find::name;

    return unless -f $file;
    return unless $file =~ m/\.t$/;

    open(my $fh, '<', $file) or die "Could not open file '$file': $!";

    my $target;
    for my $line (<$fh>) {
        if ($line eq qq{skip_all "write me";\n}) {
            $have_stubs{$file} = 1;
            return;
        }

        if ($line =~ m/^use Test2::V0 -target => (\S+)/) {
            $target = $1;
            $target =~ s/^['"]//g;
            $target =~ s/;$//g;
            $target =~ s/['"]?$//g;
        }
    }

    if ($target) {
        print "Found test for package '$target' in '$file'.\n";
        $have_pkg{$target} = $file;
    }
}

sub need_stub {
    my $file = $File::Find::name;

    return unless -f $file;
    return unless $file =~ m/\.pm$/;

    open(my $fh, '<', $file) or die "Could not open file '$file': $!";
    for my $line (<$fh>) {
        next unless $line =~ m/^use Test2::Harness::Util::Deprecated/;
        print "No stub for deprecated file '$file\n";
        return;
    }

    my $stub = $file;
    $stub =~ s{^/?lib/}{t/unit/}g;
    $stub =~ s{\.pm$}{.t};

    my $pkg  = $file;
    $pkg =~ s{^/?lib/}{};
    $pkg =~ s{/}{::}g;
    $pkg =~ s{\.pm$}{}g;

    $need_stubs{$stub} = $pkg;
}

for my $stub (sort keys %have_stubs) {
    print "Removing stub: $stub\n";
    unlink($stub) or warn "Could not remove stub: $!";
}

my @late_output;
for my $stub (sort keys %need_stubs) {
    my $pkg = $need_stubs{$stub};

    if (my $test = $have_pkg{$pkg}) {
        push @late_output => "$pkg has test in '$test', consider renaming to '$stub'.\n";
        next;
    }

    my $dir = $stub;
    $dir =~ s{[^/]+$}{};
    make_path($dir);

    my $use_target = 1;
    $use_target &&= $pkg !~ m/Schema/;
    $use_target &&= do { my $out; capture { $out = system($^X, '-Ilib', '-e' => "use $pkg; exit(0)") }; !$out };

    my $target;
    if ($use_target) {
        print "Creating stub '$stub' for $pkg\n";
        $target = " -target => '$pkg';";
    }
    else {
        print "Creating stub '$stub' for $pkg (no target)\n";
        $target = "; # -target => '$pkg'"
    }

    open(my $fh, '>', $stub) or die "Could not create stub $stub: $!";
    print $fh <<"    EOT";
use Test2::V0$target

skip_all "write me";

done_testing;
    EOT
}

print @late_output;

