#!/usr/bin/env perl
use strict;
use warnings;

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

    my $pod = generate_pod($pkg) or die "Could not get usage POD!";

    $pod = join "\n\n" => start(), $pod, ending();

    my $found;
    my @lines;
    open(my $fh, '<', $fq) or die "Could not open file '$fq' for reading: $!";
    while(my $line = <$fh>) {
        if ($line eq "=head1 POD IS AUTO-GENERATED\n") {
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

    die "FIXME";

    my $cmd = $class->name;
    my (@args) = $class->doc_args;

    my $options = App::Yath::Options->new();
    require App::Yath;
    my $ay = App::Yath->new();
    $options->include($ay->load_options);
    $options->set_command_class($class);
    my $pre_opts = $options->pre_docs('pod', head => 3);
    my $cmd_opts = $options->cmd_docs('pod', head => 3);

    my $usage = "    \$ yath [YATH OPTIONS] $cmd";

    my @head2s;

    push @head2s => ("=head2 YATH OPTIONS",    $pre_opts) if $pre_opts;

    if ($cmd_opts) {
        $usage .= " [COMMAND OPTIONS]";
        push @head2s => ("=head2 COMMAND OPTIONS", $cmd_opts);
    }

    if (@args) {
        $usage .= " [COMMAND ARGUMENTS]";

        push @head2s => (
            "=head2 COMMAND ARGUMENTS",
            "=over 4",
            (map { ref($_) ? ( "=item $_->[0]", $_->[1] ) : ("=item $_") } @args),
            "=back"
        );
    }

    my @out = (
        "=head1 NAME",
        "$class - " . $class->summary,
        "=head1 DESCRIPTION",
        $class->description,
        "=head1 USAGE",
        $usage,
        @head2s
    );

    return join("\n\n" => grep { $_ } @out);
}


sub start {
    return ("=pod", "=encoding UTF-8");
}

sub ending {
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    $year = $year + 1900;

    return <<"    EOT"
=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist\@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist\@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright $year Chad Granum E<lt>exodist7\@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
    EOT
}
