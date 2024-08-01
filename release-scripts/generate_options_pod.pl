#!/usr/bin/env perl
use strict;
use warnings;


die "No directory specified" unless @ARGV;
chdir($ARGV[0]) or die "Could not chdir to $ARGV[0]";

unshift @INC => './lib';

require App::Yath::Command;

my @bad;
for my $base ('./lib/App/Yath/Options', './lib/App/Yath/Plugin', './lib/App/Yath/Renderer') {
    opendir(my $dh, $base) or die "Could not open dir '$base': $!";

    for my $file (readdir($dh)) {
        eval { handle_file($base, $file); 1 } and next;
        warn $@;
        push @bad => "$base/$file";
    }
}

exit(0) unless @bad;

print STDERR "The following files had errors\n";
print STDERR "  $_\n" for @bad;
print STDERR "\n";
exit 1;

sub handle_file {
    my ($base, $file) = @_;

    return unless $file =~ m/\.pm$/;
    my $fq = "$base/$file";

    my $rel = $fq;
    $rel =~ s{^\./lib/}{}g;

    my $pkg = $rel;
    $pkg =~ s{/}{::}g;
    $pkg =~ s{\.pm$}{}g;

    unless (eval { require $rel; 1 }) {
        return if $@ =~ m/deprecated/i;
        die $@;
    }

    return unless $pkg->can('options');
    my $options = $pkg->options or next;
    my $opts    = $options->docs('pod', applicable => 1, groups => {':{' => '}:'}, head => 2) or die "Could not generate options docs for $pkg - $base/$file";
    my $pod     = "=head1 PROVIDED OPTIONS\n\n$opts\n";

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

    return unless $found;

    open($fh, '>', $fq) or die "Could not open file '$fq' for writing: $!";
    print $fh @lines;
    close($fh);
}
