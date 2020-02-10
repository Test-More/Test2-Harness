#!/usr/bin/env perl
use strict;
use warnings;

require App::Yath::Command;

die "No directory specified" unless @ARGV;
chdir($ARGV[0]) or die "Could not chdir to $ARGV[0]";

unshift @INC => './lib';

my $base = './lib/App/Yath/Options';

opendir(my $dh, $base) or die "Could not open options dir!";

for my $file (readdir($dh)) {
    next unless $file =~ m/\.pm$/;
    my $fq = "$base/$file";

    my $rel = $fq;
    $rel =~ s{^\./lib/}{}g;

    my $pkg = $rel;
    $pkg =~ s{/}{::}g;
    $pkg =~ s{\.pm$}{}g;

    require $rel;

    my $options = $pkg->options or die "No options in $pkg!";
    $options->set_command_class('App::Yath::Command');
    my $pre_opts = $options->pre_docs('pod', 3);
    my $cmd_opts = $options->cmd_docs('pod', 3);
    die "No option docs?" unless $pre_opts || $cmd_opts;

    my $pod = "=head1 PROVIDED OPTIONS\n\n";

    if ($pre_opts) {
        $pod .= "=head2 YATH OPTIONS (PRE-COMMAND)\n\n";
        $pod .= $pre_opts;
    }

    $pod .= "\n\n" if $pre_opts && $cmd_opts;

    if ($cmd_opts) {
        $pod .= "=head2 COMMAND OPTIONS\n\n";
        $pod .= $cmd_opts;
    }

    $pod .= "\n";

    my $found;
    my @lines;
    open(my $fh, '<', $fq) or die "Could not open file '$fq' for reading: $!";
    while(my $line = <$fh>) {
        if ($line eq "=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED\n") {
            $found++;
            push @lines => $pod;
            next;
        }

        push @lines => $line;
    }
    close($fh);

    next unless $found;
    die "Could not find line to replace in $fq" unless $found;

    open($fh, '>', $fq) or die "Could not open file '$fq' for writing: $!";
    print $fh @lines;
    close($fh);
}
