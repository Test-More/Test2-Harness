use Test2::V0;

use Test2::Harness::Util qw/file2mod/;
use File::Find;

my @files;
find(\&wanted, 'lib/');

sub wanted {
    my $file = $File::Find::name;
    return unless $file =~ m/\.pm$/;

    my $mod = $file;
    $mod =~ s{^.*lib/}{}g;
    $mod = file2mod($mod);

    push @files => [$file, $mod];
};

my %bad_files;
for my $set (@files) {
    my ($file, $mod) = @$set;

    my @res;
    subtest $file => sub {

        open(my $fh, '<', "$file") or die "Could not open file '$file': $!";

        my $pkg_line;
        while (my $line = <$fh>) {
            next unless $line =~ m/^package\s+(\S+);/;
            chomp($pkg_line = $line);
            last;
        }

        $pkg_line =~ s/Schema::Result/Schema::MySQL/      if $file =~ m{MySQL}      && $pkg_line !~ m/MySQL/;
        $pkg_line =~ s/Schema::Result/Schema::MySQL56/    if $file =~ m{MySQL56}    && $pkg_line !~ m/MySQL56/;
        $pkg_line =~ s/Schema::Result/Schema::Overlay/    if $file =~ m{Overlay}    && $pkg_line !~ m/Overlay/;
        $pkg_line =~ s/Schema::Result/Schema::Percona/    if $file =~ m{Percona}    && $pkg_line !~ m/Percona/;
        $pkg_line =~ s/Schema::Result/Schema::PostgreSQL/ if $file =~ m{PostgreSQL} && $pkg_line !~ m/PostgreSQL/;
        $pkg_line =~ s/Schema::Result/Schema::SQLite/     if $file =~ m{SQLite}     && $pkg_line !~ m/SQLite/;

        push @res => is($pkg_line, "package $mod;", "$file has correct package $mod", "Incorrect: $pkg_line");

        my $found;
        while (my $line = <$fh>) {
            chomp($line);
            if ($line eq "=head1 POD IS AUTO-GENERATED") {
                $found = 1;
                last;
            }
            next unless $line eq '=head1 NAME';

            $found = 1;

            my $space = <$fh> // last;
            chomp(my $check = <$fh> // '');
            push @res => like($check, qr/^\Q$mod - \E.+$/, "$file POD has correct package '$mod' under NAME", "Incorrect: $check");

            last;
        }

        push @res => ok($found, "Found 'NAME' section in $file POD");
    };

    next unless grep { !$_ } @res;
    $bad_files{$file} = $mod;
}

if (keys %bad_files) {
    my $diag = "All files with errors:\n";
    for my $file (sort keys %bad_files) {
        $diag .= "$file\n";
    }

    diag $diag;
}

done_testing;
