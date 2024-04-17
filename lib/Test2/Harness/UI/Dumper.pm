package Test2::Harness::UI::Dumper;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::UI::Util qw/format_duration/;
use Test2::Harness::Util::JSON qw/encode_json/;
use Test2::Harness::UI::UUID qw/uuid_inflate/;
use Time::HiRes qw/time/;
use Parallel::Runner;
use IO::Compress::Bzip2;

use Test2::Harness::Util::HashBase qw{
    <config
    <procs
};

my @DUMP_ORDER = qw{
    User
    Email
    PrimaryEmail
    Host
    EmailVerificationCode
    Session
    SessionHost
    ApiKey
    LogFile
    Project
    Permission
    Run
    Sweep
    RunField
    TestFile
    Job
    JobField
    Event
    Binary
    SourceFile
    SourceSub
    CoverageManager
    Coverage
    Reporting
    ResourceBatch
    Resource
};

sub dump {
    my $self = shift;

    my $start_all = time;
    my $runner = Parallel::Runner->new($self->{+PROCS});

    my $config = $self->config;
    my $schema = $config->schema;
    mkdir("./dump") unless -d "./dump";

    my %seen;
    for my $source (@DUMP_ORDER, $schema->sources) {
        next if $seen{$source}++;

        my $rs        = $schema->resultset($source);
        my $res       = $rs->search(undef, {page => 1, rows => $ENV{PAGE_SIZE} // 2000});
        my $pager     = $res->pager;
        my $cols_info = $rs->result_source->columns_info;

        my $pages = $pager->last_page;
        my $page  = $pager->first_page;
        my $len   = length($pages);

        while ($page <= $pages) {
            my $file = "./dump/${source}-" . sprintf("%0${len}d", $page) . ".jsonl.bz2";
            die "Dump file '$file' already exists!\n" if -e $file;

            $runner->run(sub {
                print "$$ $source STARTED ($page/$pages) -> $file\n";
                my $fh = IO::Compress::Bzip2->new("./dump/${source}-" . sprintf("%0${len}d", $page) . ".jsonl.bz2") or die "Could not open log file: $IO::Compress::Bzip2::Bzip2Error";

                my $start_page = time;
                my $page_rs    = $res->page($page);
                my $count      = 0;
                while (my $it = $page_rs->next) {
                    $count++;
                    my %data = ();
                    for my $col (keys %$cols_info) {
                        $data{$col} = $it->get_column($col);

                        my $spec = $cols_info->{$col};
                        next if $col eq 'trace_id';
                        next
                            unless ($spec->{data_type} eq 'uuid')
                            || ($spec->{data_type} eq 'binary' && $spec->{size} == 16)
                            || ($spec->{data_type} eq 'char'   && $spec->{size} == 36);

                        $data{$col} = defined($data{$col}) ? uuid_inflate($data{$col})->string : undef;
                    }

                    print $fh encode_json(\%data), "\n";
                }

                print "$$ $source [" . format_duration(time - $start_page) . " / " . format_duration(time - $start_all) . "] ($page/$pages) +$count\n";
            });

            $page++;
        }
    }

    $runner->finish();

    print "\nCompleted in " . format_duration(time - $start_all) . "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Dumper - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

