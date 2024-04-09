#!/usr/bin/env perl
use strict;
use warnings;


die "No directory specified" unless @ARGV;
chdir($ARGV[0]) or die "Could not chdir to $ARGV[0]";

unshift @INC => './lib';

require App::Yath::Command;

for my $base ('./lib/App/Yath/Options', './lib/App/Yath/Plugin') {
    opendir(my $dh, $base) or die "Could not open dir '$base': $!";

    for my $file (readdir($dh)) {
        next unless $file =~ m/\.pm$/;
        my $fq = "$base/$file";

        my $rel = $fq;
        $rel =~ s{^\./lib/}{}g;

        my $pkg = $rel;
        $pkg =~ s{/}{::}g;
        $pkg =~ s{\.pm$}{}g;

        unless (eval { require $rel; 1 }) {
            next if $@ =~ m/deprecated/i;
            die $@;
        }

        next unless $pkg->can('options');
        my $options = $pkg->options or next;
        my $opts = $options->docs('pod', groups => {':{' => '}:'}, head => 2);
        my $pod = "=head1 PROVIDED OPTIONS\n\n$opts\n";

        my $found;
        my @lines;
        open(my $fh, '<', $fq) or die "Could not open file '$fq' for reading: $!";
        while (my $line = <$fh>) {
            if ($line eq "=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED\n") {
                $found++;
                push @lines => $pod;
                next;
            }

            push @lines => $line;
        }
        close($fh);

        next unless $found;

        open($fh, '>', $fq) or die "Could not open file '$fq' for writing: $!";
        print $fh @lines;
        close($fh);
    }
}
