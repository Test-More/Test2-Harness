package Test2::Harness::UI::Loader;
use strict;
use warnings;

our $VERSION = '0.000136';

use Test2::Harness::UI::Util qw/format_duration/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::UI::UUID qw/uuid_deflate/;
use Time::HiRes qw/time/;
use Parallel::Runner;
use IO::Uncompress::Bunzip2;

use Test2::Harness::UI::Util::HashBase qw{
    <config
    <procs
};

my @LOAD_ORDER = (
    [qw/User Email Host Session LogFile TestFile SourceFile SourceSub CoverageManager/],
    [qw/PrimaryEmail ApiKey Project/],
    [qw/EmailVerificationCode SessionHost Permission Run/],
    [qw/Sweep RunField Job ResourceBatch/],
    [qw/JobField Event Coverage Resource/],
    [qw/Binary Reporting/],
);

my %VALID = map { map {($_ => 1)} @{$_} } @LOAD_ORDER;

sub load {
    my $self = shift;

    my $start_all = time;

    my %todo;
    my %seq;

    opendir(my $dh, './dump') or die "Could not open dump dir: $!";
    for my $file (sort readdir($dh)) {
        next unless $file =~ m/^(.+)-(\d+)\.jsonl\.bz2$/;
        my ($type, $seq) = ($1, $2);
        die "'$type' is not a valid type.\n" unless $VALID{$type};
        $seq{$type}++;
        die "Expected $seq{$type} got $seq.\n" unless $seq =~ m/^0+$/ or int($seq) eq $seq{$type};
        push @{$todo{$type} //= []} => "./dump/$file";
    }

    my $s = 0;
    for my $set (@LOAD_ORDER) {
        my $start_set = time;
        $s++;
        print "\n== START SET $s ==\n\n";
        my $runner = Parallel::Runner->new($self->{+PROCS});

        for my $source (@$set) {
            my $config    = $self->config;
            my $schema    = $config->schema;
            my $rs        = $schema->resultset($source);
            my $cols_info = $rs->result_source->columns_info;

            my $i = 0;
            for my $file (@{$todo{$source} //= []}) {
                $i++;
                my $pageinfo = "$i/" . scalar(@{$todo{$source}});
                $runner->run(sub {
                    my $start = time;
                    print "$$ $source STARTED ($pageinfo) <- $file\n";
                    my $fh = IO::Uncompress::Bunzip2->new($file) or die "Could not open log file: $IO::Uncompress::Bunzip2::Bzip2Error";

                    my $count = 0;
                    while (my $line = <$fh>) {
                        chomp($line);
                        $count++;

                        my $row = decode_json($line);

                        for my $col (keys %$cols_info) {
                            my $spec = $cols_info->{$col};
                            next if $col eq 'trace_id';
                            next
                                unless ($spec->{data_type} eq 'uuid')
                                || ($spec->{data_type} eq 'binary' && $spec->{size} == 16)
                                || ($spec->{data_type} eq 'char'   && $spec->{size} == 36);

                            $row->{$col} = uuid_deflate($row->{$col});
                        }

                        my $ok  = eval { $rs->create($row); 1 };
                        my $err = $@;
                        next if $ok;

                        next if $err =~ m/Duplicate entry/ && $ENV{IGNORE_DUPLICATES};

                        die $@;
                    }

                    print "$$ $source [" . format_duration(time - $start) . " / " . format_duration(time - $start_all) . "] ($pageinfo) +$count\n";
                });
            }
        }

        $runner->finish();
        print "\n== END SET $s " . format_duration(time - $start_set) . " / " . format_duration(time - $start_all) . "==\n";
    }

    print "\nCompleted in " . format_duration(time - $start_all) . "\n";
}

1;
