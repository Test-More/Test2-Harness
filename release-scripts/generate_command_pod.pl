#!/usr/bin/env perl
use strict;
use warnings;

die "No directory specified" unless @ARGV;
chdir($ARGV[0]) or die "Could not chdir to $ARGV[0]";

unshift @INC => './lib';

my $base = './lib/App/Yath/Command';

opendir(my $dh, $base) or die "Could not open command dir!";

my @bad;
for my $file (readdir($dh)) {
    eval { handle_file($file); 1 } and next;
    warn $@;
    push @bad => "$base/$file";
}

exit(0) unless @bad;

print STDERR "The following files had errors\n";
print STDERR "  $_\n" for @bad;
print STDERR "\n";
exit 1;

sub handle_file {
    my $file = shift;

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

    my $pod = generate_pod($pkg) or die "Could not get usage POD!";

    $pod = join "\n\n" => start(), $pod, ending();

    my $found;
    my @lines;
    open(my $fh, '<', $fq) or die "Could not open file '$fq' for reading: $!";
    while(my $line = <$fh>) {
        if ($line =~ "^=head1 POD IS AUTO-GENERATED") {
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

sub generate_pod {
    my $class = shift;

    my $cmd = $class->name;
    my (@args) = $class->cli_args;

    my $usage = "    \$ yath [YATH OPTIONS] $cmd [COMMAND OPTIONS]";
    $usage .= " [COMMAND ARGUMENTS]" if @args && length($args[0]);

    my @out = (
        "=head1 NAME",
        "$class - " . $class->summary,
        "=head1 DESCRIPTION",
        $class->description,
        "=head1 USAGE",
        $usage,
    );

    if ($class->can('options')) {
        my $options = $class->options();
        my $opts = $options->docs('pod', groups => {':{' => '}:'}, head => 3);

        push @out => ("=head2 OPTIONS", $opts);
    }

    return join("\n\n" => grep { $_ } @out);
}

sub start {
    return ("=pod", "=encoding UTF-8");
}

sub ending {
    return <<"    EOT"
=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist\@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist\@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7\@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
    EOT
}
