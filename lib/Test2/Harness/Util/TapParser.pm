package Test2::Harness::Util::TapParser;
use strict;
use warnings;

our $VERSION = '0.001078';

use Importer 'Importer' => 'import';

our @EXPORT_OK = qw{
    parse_stdout_tap
    parse_stderr_tap
};

sub parse_stdout_tap {
    my ($line) = @_;
    my $facet_data = __PACKAGE__->parse_tap_line($line) or return undef;
    $facet_data->{from_tap} = { source => 'STDOUT', details => $line };
    return $facet_data;
}


sub parse_stderr_tap {
    my ($line) = @_;

    # STDERR only has comments
    return unless $line =~ m/^\s*#/;

    my $facet_data = __PACKAGE__->parse_tap_line($line) or return undef;
    $facet_data->{info}->[-1]->{tag} = 'DIAG';
    $facet_data->{info}->[-1]->{debug} = 1;
    $facet_data->{from_tap} = { source => 'STDERR', details => $line };

    return $facet_data;
}

sub parse_tap_line {
    my $class = shift;
    my ($line) = @_;
    chomp($line);

    my ($lead, $lead_len, $nest, $str) = ('', 0, 0, $line);
    if ($line =~ m/^(\s+)\S/) {
        $lead = $1;
        $str =~ s/^\Q$lead\E//mg;

        $lead =~ s/\t/    /g;
        $lead_len = length($lead);

        # indentation other than 0 or a multiple of 4 spaces... not an event
        return undef if $lead_len % 4;

        $nest = $lead_len / 4;
    }

    my @types = qw/buffered_subtest comment plan bail version/;
    for my $type (@types) {
        my $sub = "parse_tap_$type";
        my $facet_data = $class->$sub($str) or next;
        $facet_data->{trace}->{nested} = $nest;
        $facet_data->{hubs}->[0]->{nested} = $nest;
        return $facet_data;
    }

    return undef;
}

sub parse_tap_buffered_subtest {
    my $class = shift;
    my ($line) = @_;

    # End of a buffered subtest.
    return {parent => {}, harness => {subtest_end => 1}} if $line =~ m/^\}\s*$/;

    my $facet_data = $class->parse_tap_ok($line) or return undef;
    return $facet_data unless $facet_data->{assert}->{details} =~ s/\s*\{\s*$//g;

    $facet_data->{parent} = {
        details => $facet_data->{assert}->{details},
    };
    $facet_data->{harness}->{subtest_start} = 1;

    return $facet_data;
}

sub parse_tap_ok {
    my $class = shift;
    my ($line) = @_;

    my ($pass, $todo, $skip, $num, @errors);

    return undef unless $line =~ s/^(not )?ok\b//;
    $pass = !$1;

    push @errors => "'ok' is not immediately followed by a space."
        if $line && !($line =~ m/^ /);

    if ($line =~ s/^(\s*)(\d+)\b//) {
        my $space = $1;
        $num = $2;

        push @errors => "Extra space after 'ok'"
            if length($space) > 1;
    }

    # Not strictly compliant, but compliant with what Test-Simple does...
    # Standard does not have a todo & skip.
    if ($line =~ s/#\s*(todo & skip|todo|skip)(.*)$//i) {
        my ($directive, $reason) = ($1, $2);

        push @errors => "No space before the '#' for the '$directive' directive."
            unless $line =~ s/\s+$//;

        push @errors => "No space between '$directive' directive and reason."
            if $reason && !($reason =~ s/^\s+//);

        $skip = $reason if $directive =~ m/skip/i;
        $todo = $reason if $directive =~ m/todo/i;
    }

    # Standard says that everything after the ok (except the number) is part of
    # the name. Most things add a dash between them, and I am deviating from
    # standards by stripping it and surrounding whitespace.
    $line =~ s/\s*-\s*//;

    $line =~ s/^\s+//;
    $line =~ s/\s+$//;

    my $is_subtest = ($line =~ m/^Subtest:\s*(.*)$/) ? ($1 or 1) : undef;

    my $facet_data = {
        assert => {
            pass     => $pass,
            no_debug => 1,
            details  => $line,
            defined $num ? (number => $num) : (),
        },
    };

    $facet_data->{parent} = {
        details => $is_subtest,
    } if defined $is_subtest;

    push @{$facet_data->{amnesty}} => {
        tag     => 'SKIP',
        details => $skip,
    } if defined $skip;

    push @{$facet_data->{amnesty}} => {
        tag     => 'TODO',
        details => $todo,
    } if defined $todo;

    push @{$facet_data->{info}} => {
        details => $_,
        debug => 1,
        tag => 'PARSER',
    } for @errors;

    return $facet_data;
}

sub parse_tap_version {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^TAP version\s/;

    return {
        about => {
            details => $line,
        },
        info => [
            {
                tag     => 'INFO',
                debug   => 0,
                details => $line,
            }
        ],
    };
}

sub parse_tap_plan {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ s/^1\.\.(\d+)//;
    my $max = $1;

    my ($directive, $reason) = ("", "");

    if ($max == 0) {
        if ($line =~ s/^\s*#\s*//) {
            if ($line =~ s/^(skip)\S*\s*//i) {
                $directive = uc($1);
                $reason = $line;
                $line = "";
            }
        }

        $directive ||= "SKIP";
        $reason    ||= "no reason given";
    }

    my $facet_data = {
        plan => {
            count   => $max,
            skip    => ($directive eq 'SKIP') ? 1 : 0,
            details => $reason,
        }
    };

    push @{$facet_data->{info}} => {
        details => 'Extra characters after plan.',
        debug => 1,
        tag => 'PARSER',
    } if $line =~ m/\S/;

    return $facet_data;
}

sub parse_tap_bail {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^Bail out!\s*(.*)$/;

    return {
        control => {
            halt => 1,
            details => $1,
        }
    };
}

sub parse_tap_comment {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^\s*#/;

    $line =~ s/^\s*# ?//msg;

    return {
        info => [
            {
                details => $line,
                tag     => 'NOTE',
                debug   => 0,
            }
        ]
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::TapParser - Produce EventFacets from a line of TAP.

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
