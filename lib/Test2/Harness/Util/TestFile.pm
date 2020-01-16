package Test2::Harness::Util::TestFile;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;

use Time::HiRes qw/time/;

use File::Spec();

use List::Util 1.45 qw/uniq/;

use Test2::Harness::Util qw/open_file/;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase qw{
    -file -_scanned -_headers -_shbang -queue_args -is_binary -non_perl
    _category _stage _duration
};

sub set_duration { $_[0]->set__duration(lc($_[1])) }
sub set_category { $_[0]->set__category(lc($_[1])) }
sub set_stage    { $_[0]->set__stage(   lc($_[1])) }

sub init {
    my $self = shift;

    my $file = $self->file;

    # We want absolute path
    $file = File::Spec->rel2abs($file);
    $self->{+FILE} = $file;

    $self->{+QUEUE_ARGS} ||= [];

    croak "Invalid test file '$file'" unless -f $file;

    if($self->{+IS_BINARY} = -B $file) {
        $self->{+NON_PERL} = 1;
        die "Cannot run binary test file '$file': file is not executable.\n"
            unless $self->is_executable;
    }
}

my %DEFAULTS = (
    timeout   => 1,
    fork      => 1,
    preload   => 1,
    stream    => 1,
    retry     => 1,
    isolation => 0,
);

sub check_feature {
    my $self = shift;
    my ($feature, $default) = @_;

    $default = $DEFAULTS{$feature} unless defined $default;

    return $default unless defined $self->headers->{features}->{$feature};
    return 1 if $self->headers->{features}->{$feature};
    return 0;
}

sub check_stage {
    my $self = shift;

    return $self->{+_STAGE} if $self->{+_STAGE};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{stage} || 'default';
}

sub meta {
    my $self = shift;
    my ($key) = @_;

    $self->_scan unless $self->{+_SCANNED};
    my $meta = $self->{+_HEADERS}->{meta} or return ();

    return () unless $key && $meta->{$key};

    return @{$meta->{$key}};
}

sub check_duration {
    my $self = shift;

    return $self->{+_DURATION} if $self->{+_DURATION};

    $self->_scan unless $self->{+_SCANNED};
    my $duration = $self->{+_HEADERS}->{duration};
    return $duration if $duration;

    my $timeout = $self->check_feature(timeout => 1);

    # 'long' for anything with no timeout
    return 'long' unless $timeout;

    return 'medium';
}

sub check_category {
    my $self = shift;

    return $self->{+_CATEGORY} if $self->{+_CATEGORY};

    $self->_scan unless $self->{+_SCANNED};
    my $category = $self->{+_HEADERS}->{category};

    return $category if $category;

    my $isolate = $self->check_feature(isolation => 0);

    # 'isolation' queue if isolation requested
    return 'isolation' if $isolate;

    return 'general';
}

sub event_timeout    { $_[0]->headers->{timeout}->{event} }
sub postexit_timeout { $_[0]->headers->{timeout}->{postexit} }

sub conflicts_list {
    return $_[0]->headers->{conflicts} || [];    # Assure conflicts is always an array ref.
}

sub headers {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_HEADERS};
    return {%{$self->{+_HEADERS}}};
}

sub shbang {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_SHBANG};
    return {%{$self->{+_SHBANG}}};
}

sub switches {
    my $self = shift;

    my $shbang   = $self->shbang       or return [];
    my $switches = $shbang->{switches} or return [];

    return $switches;
}

sub is_executable {
    my $self = shift;
    my ($file) = @_;
    $file //= $self->{+FILE};
    return -x $file;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;
    return if $self->{+IS_BINARY};

    my $fh = open_file($self->{+FILE});

    my %headers;
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        chomp($line);
        next if $line =~ m/^\s*$/;

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang) {
                $self->{+_SHBANG} = $shbang;

                if ($shbang->{non_perl}) {
                    $self->{+NON_PERL} = 1;

                    die "Cannot run non-perl test file '" . $self->{+FILE} . "': file is not executable.\n"
                        unless $self->is_executable;
                }

                next;
            }
        }

        next if $line =~ m/^\s*#/ && $line !~ m/^\s*#\s*HARNESS-.+/;    # Ignore commented lines which aren't HARNESS-?
        next if $line =~ m/^\s*(use|require|BEGIN|package)\b/;          # Only supports single line BEGINs
        last unless $line =~ m/^\s*#\s*HARNESS-(.+)$/;

        my ($dir, $rest) = split /[-\s]+/, lc($1), 2;
        my @args;
        if ($dir eq 'meta') {
            @args = split /\s+/, $rest, 2;                              # Check for white space delimited
            @args = split(/[-]+/, $rest, 2) if scalar @args == 1;       # Check for dash delimited
            $args[1] =~ s/\s+(?:#.*)?$//;                               # Strip trailing white space and comment if present
        }
        else {
            $rest =~ s/\s+(?:#.*)?$//;                                  # Strip trailing white space and comment if present
            @args = split /[-\s]+/, $rest;
        }

        if ($dir eq 'no') {
            my ($feature) = @args;
            $headers{features}->{$feature} = 0;
        }
        elsif ($dir eq 'yes' || $dir eq 'use') {
            my ($feature) = @args;
            $headers{features}->{$feature} = 1;
        }
        elsif ($dir eq 'stage') {
            my ($name) = @args;
            $headers{stage} = $name;
        }
        elsif ($dir eq 'meta') {
            my ($key, $val) = @args;
            push @{$headers{meta}->{$key}} => $val;
        }
        elsif ($dir eq 'duration' || $dir eq 'dur') {
            my ($name) = @args;
            $headers{duration} = $name;
        }
        elsif ($dir eq 'category' || $dir eq 'cat') {
            my ($name) = @args;
            if ($name =~ m/^(long|medium|short)$/i) {
                $headers{duration} = $name;
            }
            else {
                $headers{category} = $name;
            }
        }
        elsif ($dir eq 'conflicts') {
            my @conflicts_array;

            foreach my $arg (@args) {
                push @conflicts_array, $arg;
            }

            # Allow multiple lines with # HARNESS-CONFLICTS FOO
            $headers{conflicts} ||= [];
            push @{$headers{conflicts}}, @conflicts_array;

            # Make sure no more than 1 conflict is ever present.
            @{$headers{conflicts}} = uniq @{$headers{conflicts}};
        }
        elsif ($dir eq 'timeout') {
            my ($type, $num) = @args;

            warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at $self->{+FILE} line $ln.\n"
                unless $type =~ m/^(event|postexit)$/;

            $headers{timeout}->{$type} = $num;
        }
        else {
            warn "Unknown harness directive '$dir' at $self->{+FILE} line $ln.\n";
        }
    }

    $self->{+_HEADERS} = \%headers;
}

sub _parse_shbang {
    my $self = shift;
    my $line = shift;

    return {} if !defined $line;

    my %shbang;

    # NOTE: Test this, the dashes should be included with the switches
    my $shbang_re = qr{
        ^
          \#!.*perl.*?        # the perl path
          (?: \s (-.+) )?       # the switches, maybe
          \s*
        $
    }xi;

    if ($line =~ $shbang_re) {
        my @switches = grep { m/\S/ } split /\s+/, $1 if defined $1;
        $shbang{switches} = \@switches;
        $shbang{line}     = $line;
    }
    elsif ($line =~ m/^#!/ && $line !~ m/perl/i) {
        $shbang{line} = $line;
        $shbang{non_perl} = 1;
    }

    return \%shbang;
}

sub queue_item {
    my $self = shift;
    my ($job_name) = @_;

    my $category = $self->check_category;
    my $duration = $self->check_duration;
    my $stage    = $self->check_stage;

    my $fork    = $self->check_feature(fork    => 1);
    my $preload = $self->check_feature(preload => 1);
    my $retry   = $self->check_feature(retry   => 1);
    my $timeout = $self->check_feature(timeout => 1);
    my $stream  = $self->check_feature(stream  => 1);

    my $binary  = $self->{+IS_BINARY} ? 1 : 0;
    my $non_perl = $self->{+NON_PERL} ? 1 : 0;

    return {
        category    => $category,
        duration    => $duration,
        file        => $self->file,
        headers     => $self->headers,
        job_id      => gen_uuid(),
        job_name    => $job_name,
        shbang      => $self->shbang,
        stage       => $stage,
        stamp       => time,
        switches    => $self->switches,
        use_fork    => $fork,
        use_preload => $preload,
        use_retry   => $retry,
        use_stream  => $stream,
        use_timeout => $timeout,
        conflicts   => $self->conflicts_list,
        binary      => $binary,
        non_perl    => $non_perl,

        event_timeout    => $self->event_timeout,
        postexit_timeout => $self->postexit_timeout,
        @{$self->{+QUEUE_ARGS}},
    };
}

my %RANK = (
    immiscible => 1,
    long       => 2,
    medium     => 3,
    short      => 4,
    isolation  => 5,
);

sub rank {
    my $self = shift;

    my $rank = $RANK{$self->check_category};
    $rank ||= $RANK{$self->check_duration};
    $rank ||= 1;

    return $rank;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::TestFile - Logic to scan a test file.

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
