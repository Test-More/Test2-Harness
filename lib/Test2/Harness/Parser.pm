package Test2::Harness::Parser;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::Fact;
use Test2::Harness::Result;

use Test2::Util::HashBase qw/listeners proc result job _morphed/;

sub parse_line { die "$_[0] does not implement parse_line()" }
sub finish     { die "$_[0] does not implement finish()"     }

sub morph {}

sub init {
    my $self = shift;

    croak "'proc' is a required attribute"
        unless $self->{+PROC};

    croak "'job' is a required attribute"
        unless $self->{+JOB};

    my $listeners = $self->{+LISTENERS} ||= [];

    $_->($self->{+JOB}, Test2::Harness::Fact->new(start => $self->{+PROC}->file)) for @$listeners;
}

sub is_done {
    my $self = shift;
    return $self->{+RESULT};
}

sub get_type {
    my $self = shift;

    my $line = $self->proc->get_out_line(peek => 1);

    if (!$line && $self->proc->is_done) {
        my $r = Test2::Harness::Result->new(
            file => $self->{+PROC}->file,
            name => $self->{+PROC}->file,
            job  => $self->{+JOB},
        );

        while (my $line = $self->proc->get_err_line) {
            chomp($line);
            $r->add_fact(
                Test2::Harness::Fact->new(
                    causes_fail => 0,
                    diagnostics => 1,
                    output      => $line,
                    parsed_from_string => $line,
                    parsed_from_handle => 'STDERR',
                ),
            );
        }

        $r->add_fact(
            Test2::Harness::Fact->new(
                causes_fail => 1,
                diagnostics => 1,
                parse_error => "No output was seen before test exited!"
            ),
        );

        $self->notify(Test2::Harness::Fact->from_result($r));
        $self->{+RESULT} = $r;
        return;
    }

    return unless $line;


    if($line =~ m/T2_FORMATTER: (.+)/) {
        my $fmt = $1;
        my $class = "Test2::Harness::Parser::$fmt";
        require(pkg_to_file($class));

        $self->proc->get_out_line; # Strip it off

        return $class;
    }

    require Test2::Harness::Parser::TAP;
    return 'Test2::Harness::Parser::TAP';
}

sub step {
    my $self = shift;

    return 0 if $self->{+RESULT};

    unless ($self->{+_MORPHED} || blessed($self) ne __PACKAGE__) {
        my $type = $self->get_type or return 0;
        bless($self, $type);
        $self->{+_MORPHED} = 1;
        $self->morph;
        return $self->step(@_);
    }

    return 0 if $self->check_for_exit;
    return 1 if $self->parse_stdout;
    return 1 if $self->parse_stderr;

    return 0;
}

sub check_for_exit {
    my $self = shift;
    my $proc = $self->{+PROC};
    return unless $proc->is_done;

    my $found = 1;
    while ($found) {
        $found = 0;
        $found += $self->parse_stdout;
        $found += $self->parse_stderr;
    }

    $self->finish($proc->exit);

    $self->notify(Test2::Harness::Fact->from_result($self->{+RESULT}));

    return 1;
}

sub parse_stderr {
    my $self = shift;

    my $line = $self->proc->get_err_line or return 0;

    $self->notify($self->parse_line(STDERR => $line));

    return 1;
}

sub parse_stdout {
    my $self = shift;
    my $line = $self->proc->get_out_line or return 0;

    $self->notify($self->parse_line(STDOUT => $line));

    return 1;
}

sub notify {
    my $self = shift;
    my (@facts) = @_;

    for my $fact (@facts) {
        $_->($self->{+JOB} => $fact) for @{$self->{+LISTENERS}};
    }
}

1;
