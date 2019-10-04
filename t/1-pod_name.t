use Test2::V0;
# HARNESS-NO-PRELOAD

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

    open(my $fh, '<', "$file") or die "Could not open file '$file': $!";

    chomp(my $start = <$fh>);
    push @res => is($start, "package $mod;", "$file has correct package $mod", "Incorrect: $start");

    my $found;
    while(my $line = <$fh>) {
        chomp($line);
        if ($line eq "=head1 POD IS AUTO-GENERATED") {
            $found = 1;
            last;
        }
        next unless $line eq '=head1 NAME';

        $found = 1;

        my $space = <$fh> // last;
        chomp(my $check = <$fh> // '');
        push @res => like($check, qr/^\Q$mod - \E.+$/, "$file POD has correct package '$mod' under NAME");

        last;
    }

    push @res => ok($found, "Found 'NAME' section in $file POD");

    next unless grep { !$_ } @res;
    $bad_files{$file} = $mod;
};

if (keys %bad_files) {
    my $diag = "All files with errors:\n";
    for my $file (sort keys %bad_files) {
        $diag .= "$file\n";
    }

    diag $diag;
}

done_testing;
