package Test2::Harness::Renderer::JUnit;
use strict;
use warnings;

our $VERSION = '0.001074';

use Carp qw/croak/;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use File::Spec;

use Storable qw/dclone/;
use XML::Generator ();

use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/fqmod/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

BEGIN { require Test2::Harness::Renderer; our @ISA = ('Test2::Harness::Renderer') }
use Test2::Harness::Util::HashBase qw{
    -io -io_err
    -formatter
    -show_run_info
    -show_job_info
    -show_job_launch
    -show_job_end
    -times
};

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    $self->{'xml'} = XML::Generator->new(':pretty', ':std', 'escape' => 'always,high-bit,even-entities', 'encoding' => 'UTF-8');

    $self->{'xml_content'} = [];

    open(my $fh, '>', 'junit.xml') or die("Can't open junit.xml ($!)");
    $self->{'junit_fh'} = $fh;

    $self->{'tests'} = {};    # We need a pointer to each test so we know where to go for each event.
}

sub render_event {
    my $self = shift;
    my ($event) = @_;

    # We modify the event, which would be bad if there were multiple renderers,
    # so we deep clone it.
    $event = dclone($event);
    my $f      = $event->{facet_data};           # Optimization
    my $job    = $f->{harness_job};
    my $job_id = $event->{'job_id'} or return;

    if ($f->{'harness_run'}) {
        # my $run = $f->{harness_run};
    }

    # At job launch we need to start collecting a new junit testdata section.
    # We throw out anything we've collected to date.
    if ($f->{'harness_job_launch'}) {
        my $full_test_name = $job->{'file'};
        my $test_file      = File::Spec->abs2rel($full_test_name);

        # Purge any previous runs of this job if we're seeing a new one starting.
        foreach my $id (keys %{$self->{'tests'}}) {
            delete $self->{'tests'}->{$id} if $self->{'tests'}->{$id}->{name} eq $full_test_name;
        }

        my $c = $self->{'tests'}->{$job_id} = {
            'name'       => $job->{'file'},
            'job_id'     => $job_id,
            'job_name'   => $f->{'harness_job'}->{'job_name'},
            'testcase'   => [],
            'system-out' => '',
            'system-err' => '',
            'start'      => $event->{'stamp'},
            'testsuite'  => {
                'errors'   => 0,
                'failures' => 0,
                'tests'    => 0,
                'name'     => $test_file,
            },
        };

        return;
    }

    my $test = $self->{'tests'}->{$job_id};

    # We have all the data. Print the XML.
    if ($f->{harness_job_end}) {
        $self->close_open_failure_testcase($test, -1);
        $test->{'stop'} = $event->{'stamp'};
        $test->{'testsuite'}->{'time'} = $test->{'stop'} - $test->{'start'};

        return;
    }

    if ($f->{'plan'}) {
        if ($f->{'plan'}->{'skip'}) {
            my $skip = $f->{'plan'}->{'details'};
            $test->{'system-out'} .= "# $skip\n";
        }
        if ($f->{'plan'}->{'count'}) {
            $test->{'plan'} = $f->{'plan'}->{'count'};
        }
    }

    # We just hit an ok/not ok line.
    if ($f->{'assert'}) {

        my $test_num  = $event->{'assert_count'};
        my $test_name = $f->{'assert'}->{'details'} // 'UNKNOWN_TEST?';
        $test->{'testsuite'}->{'tests'}++;

        $self->close_open_failure_testcase($test, $test_num);

        if ($f->{'assert'}->{'pass'}) {
            push @{$test->{'testcase'}}, $self->xml->testcase({'name' => "$test_num - $test_name"}, "");
        }
        else {
            $test->{'testsuite'}->{'failures'}++;
            $test->{'testsuite'}->{'errors'}++;

            # Trap the test information. We can't generate the XML for this test until we get all the diag information.
            $test->{'last_failure'} = {
                test_num  => $test_num,
                test_name => $test_name,
                message   => "not ok $test_num - $test_name\n",
            };

            #print Dumper $event;
        }

        return;
    }

    if ($f->{'info'} && $test->{'last_failure'}) {
        foreach my $line (@{$f->{'info'}}) {
            next unless $line->{'details'};
            chomp $line->{'details'};
            $test->{'last_failure'}->{'message'} .= "# $line->{details}\n";
        }
        return;
    }

    #print Dumper $event;
}

sub finish {
    my $self = shift;

    my $fh = $self->{'junit_fh'};
    seek $fh, 0, 0;
    truncate $fh, 0;

    my $xml = $self->xml;

    my $out_method = 'system-out';
    my $err_method = 'system-err';

    print {$fh} $xml->testsuites(
        map {
            $xml->testsuite(
                $_->{'testsuite'},
                @{$_->{'testcase'}},
                $xml->$out_method($self->_cdata($_->{$out_method})),
                $xml->$err_method($self->_cdata($_->{$err_method})),
                )
            }
            sort { $a->{'job_name'} <=> $b->{'job_name'} } values %{$self->{'tests'}}
    ) . "\n";

    return;
}

sub close_open_failure_testcase {
    my ($self, $test, $new_test_number) = @_;

    # Need to handle failed TODOs
    
    # The last test wasn't a fail.
    return unless $test->{'last_failure'};

    my $fail = $test->{'last_failure'};
    if ($fail->{'test_num'} == $new_test_number) {
        die("The same assert number ($new_test_number) was seen twice for $test->{name}");
    }

    my $xml = $self->xml;
    push @{$test->{'testcase'}}, $xml->testcase(
        {'name' => "$fail->{test_num} - $fail->{test_name}"},
        $xml->failure(
            {'message' => "not ok $fail->{test_num} - $fail->{test_name}", 'type' => 'TestFailed'},
            $self->_cdata($fail->{'message'})
        )
    );

    delete $test->{'last_failure'};
    return;
}

sub xml {
    my $self = shift;
    return $self->{'xml'};
}

###############################################################################
# Checks for bogosity in the test result.
sub _check_for_test_bogosity {
    my $self   = shift;
    my $result = shift;

    if ($result->todo_passed() && !$self->passing_todo_ok()) {
        return {
            level   => 'error',
            type    => 'TodoTestSucceeded',
            message => $result->explanation(),
        };
    }

    if ($result->is_unplanned()) {
        return {
            level   => 'error',
            type    => 'UnplannedTest',
            message => $result->as_string(),
        };
    }

    if (not $result->is_ok()) {
        return {
            level   => 'failure',
            type    => 'TestFailed',
            message => $result->as_string(),
        };
    }

    return;
}

###############################################################################
# Generates the name for a test case.
sub _get_testcase_name {
    my $test = shift;
    my $name = join(' ', $test->number(), _clean_test_description($test));
    $name =~ s/\s+$//;
    return $name;
}

###############################################################################
# Generates the name for the entire test suite.
sub _get_testsuite_name {
    my $self = shift;
    my $name = $self->name;
    $name =~ s{^\./}{};
    $name =~ s{^t/}{};
    return _clean_to_java_class_name($name);
}

###############################################################################
# Cleans up the given string, removing any characters that aren't suitable for
# use in a Java class name.
sub _clean_to_java_class_name {
    my $str = shift;
    $str =~ s/[^-:_A-Za-z0-9]+/_/gs;
    return $str;
}

###############################################################################
# Cleans up the description of the given test.
sub _clean_test_description {
    my $test = shift;
    my $desc = $test->description();
    return _squeaky_clean($desc);
}

###############################################################################
# Creates a CDATA block for the given data (which is made squeaky clean first,
# so that JUnit parsers like Hudson's don't choke).
sub _cdata {
    my ($self, $data) = @_;
    return $data if (!$data or $data !~ m/\S/ms);
    $data = _squeaky_clean($data);
    return $self->xml->xmlcdata($data);
}

###############################################################################
# Clean a string to the point that JUnit can't possibly have a problem with it.
sub _squeaky_clean {
    my $string = shift;
    # control characters (except CR and LF)
    $string =~ s/([\x00-\x09\x0b\x0c\x0e-\x1f])/"^".chr(ord($1)+64)/ge;
    # high-byte characters
    $string =~ s/([\x7f-\xff])/'[\\x'.sprintf('%02x',ord($1)).']'/ge;
    return $string;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Renderer::JUnit - writes a junit.xml file

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness-Renderer-JUnit can be found at
F<http://github.com/.../>.

=head1 MAINTAINERS

=over 4

=item Todd Rinaldo <lt>toddr@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Todd Rinaldo <lt>toddr@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Todd Rinaldo<lt>toddr@cpan.orgE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
