#!/usr/bin/env perl

die "No directory specified" unless @ARGV;
chdir($ARGV[0]) or die "Could not chdir to $ARGV[0]";

unshift @INC => './lib';

my $base = './lib/App/Yath/Command';

opendir(my $dh, $base) or die "Could not open command dir!";

for my $file (readdir($dh)) {
    next unless $file =~ m/\.pm$/;
    my $fq = "$base/$file";

    my $rel = $fq;
    $rel =~ s{^\./lib/}{}g;

    my $pkg = $rel;
    $pkg =~ s{/}{::}g;
    $pkg =~ s{\.pm$}{}g;

    require $rel;

    my $pod = $pkg->usage_pod or die "Could not get usage POD!";

    my $found;
    my @lines;
    open(my $fh, '<', $fq) or die "Could not open file '$fq' for reading: $!";
    while(my $line = <$fh>) {
        if ($line eq "B<THIS SECTION IS AUTO-GENERATED AT BUILD>\n") {
            $found++;
            push @lines => $pod;
            next;
        }

        push @lines => $line;
    }
    close($fh);

    die "Could not find line to replace in $fq" unless $found;

    open($fh, '>', $fq) or die "Could not open file '$fq' for writing: $!";
    print $fh @lines;
    close($fh);
}
