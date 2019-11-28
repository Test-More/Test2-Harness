package Test2::Harness::Renderer::JUnit;
use strict;
use warnings;

our $VERSION = '0.001077';

# This is used frequently during development to determine what different events look like so we can determine how to capture test data.
#use Data::Dumper; $Data::Dumper::Sortkeys = 1;

use File::Spec;
use Storable qw/dclone/;
use XML::Generator ();

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

    my $settings = $self->{ +SETTINGS };

    $self->{'xml'} = XML::Generator->new( ':pretty', ':std', 'escape' => 'always,high-bit,even-entities', 'encoding' => 'UTF-8' );

    $self->{'xml_content'} = [];

    $self->{'allow_passing_todos'} = $ENV{'ALLOW_PASSING_TODOS'} ? 1 : 0;
    $self->{'junit_file'} //= $ENV{'JUNIT_TEST_FILE'} || 'junit.xml';

    $self->{'tests'} = {};    # We need a pointer to each test so we know where to go for each event.
}

# This sub is called for every Harness event. We capture the data we need so we can emit the appropriate junit file.

sub render_event {
    my $self = shift;
    my ($event) = @_;

    # We modify the event, which would be bad if there were multiple renderers,
    # so we deep clone it.
    $event = dclone($event);
    my $f      = $event->{facet_data};
    my $job    = $f->{harness_job};
    my $job_id = $event->{'job_id'} or return;
    my $stamp  = $event->{'stamp'} || die "No time stamp found for event?!?!?!?";

    # At job launch we need to start collecting a new junit testdata section.
    # We throw out anything we've collected to date.
    if ( $f->{'harness_job_launch'} ) {
        my $full_test_name = $job->{'file'};
        my $test_file      = File::Spec->abs2rel($full_test_name);

        # Purge any previous runs of this job if we're seeing a new one starting.
        foreach my $id ( keys %{ $self->{'tests'} } ) {
            delete $self->{'tests'}->{$id} if $self->{'tests'}->{$id}->{name} eq $full_test_name;
        }

        $self->{'tests'}->{$job_id} = {
            'name'           => $job->{'file'},
            'job_id'         => $job_id,
            'job_name'       => $f->{'harness_job'}->{'job_name'},
            'testcase'       => [],
            'system-out'     => '',
            'system-err'     => '',
            'start'          => $stamp,
            'last_job_start' => $stamp,
            'testsuite'      => {
                'errors'   => 0,
                'failures' => 0,
                'tests'    => 0,
                'name'     => _get_testsuite_name($test_file),
            },
        };

        return;
    }

    my $test = $self->{'tests'}->{$job_id};

    # We have all the data. Print the XML.
    if ( $f->{'harness_job_end'} ) {
        $self->close_open_failure_testcase( $test, -1 );
        $test->{'stop'} = $event->{'stamp'};
        $test->{'testsuite'}->{'time'} = $test->{'stop'} - $test->{'start'};

        push @{ $test->{'testcase'} }, $self->xml->testcase( { 'name' => "Tear down.", 'time' => $stamp - $test->{'last_job_start'} }, "" );

        if ( $f->{'errors'} ) {
            $test->{'error-msg'} //= '';
            foreach my $msg ( @{ $f->{'errors'} } ) {
                next unless $msg->{'from_harness'};
                next unless $msg->{'tag'} // '' eq 'REASON';

                if ( $msg->{details} =~ m/^Planned for ([0-9]+) assertions?, but saw ([0-9]+)/ ) {
                    $test->{'testsuite'}->{'errors'} += $1 - $2;
                }

                $test->{'error-msg'} .= "$msg->{details}\n";
            }
        }

        return;
    }

    if ( $f->{'plan'} ) {
        if ( $f->{'plan'}->{'skip'} ) {
            my $skip = $f->{'plan'}->{'details'};
            $test->{'system-out'} .= "# SKIP $skip\n";
        }
        if ( $f->{'plan'}->{'count'} ) {
            $test->{'plan'} = $f->{'plan'}->{'count'};
        }

        return;
    }

    if ( $f->{'harness_job_exit'} ) {
        return unless $f->{'harness_job_exit'}->{'exit'};

        # If we don't see
        $test->{'testsuite'}->{'errors'}++;
        $test->{'error-msg'} //= $f->{'harness_job_exit'}->{'details'} . "\n";

        return;
    }

    # We just hit an ok/not ok line.
    if ( $f->{'assert'} ) {

        # Ignore subtests
        return if ( $f->{'hubs'} && $f->{'hubs'}->[0]->{'nested'} );

        my $test_num    = sprintf( "%04d", $event->{'assert_count'} || $f->{'assert'}->{'number'} || die Dumper $event);
        my $test_name   = _squeaky_clean( $f->{'assert'}->{'details'} // 'UNKNOWN_TEST?' );
        my $test_string = defined $test_name ? "$test_num - $test_name" : $test_num;
        $test->{'testsuite'}->{'tests'}++;

        $self->close_open_failure_testcase( $test, $test_num );

        warn Dumper $event unless $stamp;

        my $run_time = $stamp - $test->{'last_job_start'};
        $test->{'last_job_start'} = $stamp;

        if ( $f->{'amnesty'} && grep { ( $_->{'tag'} // '' ) eq 'TODO' } @{ $f->{'amnesty'} } ) {    # All TODO Tests
            if ( !$f->{'assert'}->{'pass'} ) {                                                       # Failing TODO
                push @{ $test->{'testcase'} }, $self->xml->testcase( { 'name' => "$test_string (TODO)", 'time' => $run_time }, "" );
            }
            elsif ( $self->{'allow_passing_todos'} ) {                                               # junit parsers don't like passing TODO tests. Let's just not tell them about it if $ENV{ALLOW_PASSING_TODOS} is set.
                push @{ $test->{'testcase'} }, $self->xml->testcase( { 'name' => "$test_string (PASSING TODO)", 'time' => $run_time }, "" );
            }
            else {                                                                                   # Passing TODO (Failure) when not allowed.

                $test->{'testsuite'}->{'failures'}++;
                $test->{'testsuite'}->{'errors'}++;

                # Grab the first amnesty description that's a TODO message.
                my ($todo_message) = map { $_->{'details'} } grep { $_->{'tag'} // '' eq 'TODO' } @{ $f->{'amnesty'} };

                push @{ $test->{'testcase'} }, $self->xml->testcase(
                    { 'name' => "$test_string (TODO)", 'time' => $run_time },
                    $self->xml->error(
                        { 'message' => $todo_message, 'type' => "TodoTestSucceeded" },
                        $self->_cdata("ok $test_string")
                    )
                );

            }
        }
        elsif ( $f->{'assert'}->{'pass'} ) {    # Passing test
            push @{ $test->{'testcase'} }, $self->xml->testcase( { 'name' => "$test_string", 'time' => $run_time }, "" );
        }
        else {                                  # Failing Test.
            $test->{'testsuite'}->{'failures'}++;
            $test->{'testsuite'}->{'errors'}++;

            # Trap the test information. We can't generate the XML for this test until we get all the diag information.
            $test->{'last_failure'} = {
                'test_num'  => $test_num,
                'test_name' => $test_name,
                'time'      => $run_time,
                'message'   => "not ok $test_string\n",
            };
        }

        return;
    }

    if ( $f->{'info'} && $test->{'last_failure'} ) {
        foreach my $line ( @{ $f->{'info'} } ) {
            next unless $line->{'details'};
            chomp $line->{'details'};
            $test->{'last_failure'}->{'message'} .= "# $line->{details}\n";
        }
        return;
    }

}

# This is called when the last run is complete and we're ready to emit the junit file.

sub finish {
    my $self = shift;

    open( my $fh, '>', $self->{'junit_file'} ) or die("Can't open '$self->{junit_file}' ($!)");

    my $xml = $self->xml;

    # These are method calls but you can't do methods with a dash in them so we have to store them as a SV and call it.
    my $out_method = 'system-out';
    my $err_method = 'system-err';

    print {$fh} $xml->testsuites(
        map {
            $xml->testsuite(
                $_->{'testsuite'},
                @{ $_->{'testcase'} },
                $xml->$out_method( $self->_cdata( $_->{$out_method} ) ),
                $xml->$err_method( $self->_cdata( $_->{$err_method} ) ),
                $_->{'error-msg'} ? $xml->error( { 'message' => $_->{'error-msg'} } ) : (),
              )
          }
          sort { $a->{'job_name'} <=> $b->{'job_name'} } values %{ $self->{'tests'} }
    ) . "\n";

    close $fh;

    return;
}

# Because we want to test diag messages after a failed test, we delay closing failures
# until we see the end of the testcase or until we see a new test number.

sub close_open_failure_testcase {
    my ( $self, $test, $new_test_number ) = @_;

    # Need to handle failed TODOs

    # The last test wasn't a fail.
    return unless $test->{'last_failure'};

    my $fail = $test->{'last_failure'};
    if ( $fail->{'test_num'} == $new_test_number ) {
        die("The same assert number ($new_test_number) was seen twice for $test->{name}");
    }

    my $xml = $self->xml;
    push @{ $test->{'testcase'} }, $xml->testcase(
        { 'name' => "$fail->{test_num} - $fail->{test_name}", 'time' => $fail->{'time'} },
        $xml->failure(
            { 'message' => "not ok $fail->{test_num} - $fail->{test_name}", 'type' => 'TestFailed' },
            $self->_cdata( $fail->{'message'} )
        )
    );

    delete $test->{'last_failure'};
    return;
}

sub xml {
    my $self = shift;
    return $self->{'xml'};
}

# These helpers were borrowed from https://metacpan.org/pod/TAP::Formatter::JUnit. Thanks!

###############################################################################
# Generates the name for the entire test suite.
sub _get_testsuite_name {
    my $name = shift;
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
# Creates a CDATA block for the given data (which is made squeaky clean first,
# so that JUnit parsers like Hudson's don't choke).
sub _cdata {
    my ( $self, $data ) = @_;

    # When I first added this conditional, I returned $data and at one point it was returning ^A and breaking the xml parser.
    return '' if ( !$data or $data !~ m/\S/ms );

    return $self->xml->xmlcdata( _squeaky_clean($data) );
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

Test2::Harness::Renderer::JUnit - Captures Test2::Harness results and emits a junit xml file.

=head1 SYNOPSIS

On the command line, with F<yath>:

  JUNIT_TEST_FILE="/tmp/foo.xml" ALLOW_PASSING_TODOS=1 yath test --renderer=Formatter --renderer=JUnit -j18 t/*.t

=head1 DESCRIPTION

C<Test2::Harness::Renderer::JUnit> provides JUnit output formatting sufficient
to be parsed by Jenkins and hopefully other junit parsers.

This code borrows many ideas from C<TAP::Formatter::JUnit> but unlike that module
does not provide a method to emit a different xml file for every testcase.
Instead, it defaults to emitting to a single B<junit.xml> to whatever the directory
was you were in when you ran yath. This can be overridden by setting the
C<JUNIT_TEST_FILE> environment variable

Timing information is included in the JUnit XML since this is native to C<Test2::Harness>

In standard use, "passing TODOs" are treated as failure conditions (and are
reported as such in the generated JUnit).  If you wish to treat these as a
"pass" and not a "fail" condition, setting C<ALLOW_PASSING_TODOS=1> in your
environment will turn these into pass conditions.

The JUnit output generated was developed to be used by Jenkins
(L<https://jenkins.io/>).  That's the build tool we use at the
moment and needed to be able to generate JUnit output for.

=head1 METHODS

=over

=item B<render_event($event)>

This is the only method (other than finish) that is called by Test2::Harness in order to
gather the data needed to emit the needed xml.

=item B<close_open_failure_testcase($test, $new_test_number)>

This method is called whenever a new test result or the end of a run is seen. Because
we want to capture test diag messages after a failed test, we delay emitting a failure
until we see the end of the testcase or until we see a new test number.

=item B<finish()>

This method is called by Test2::Harness when all runs are complete. It takes what has
been gathered to that point and creates the junit xml file.

=item xml

An C<XML::Generator> instance, to be used to generate XML output.

=item init

This subroutine is called during object initialization for Test2::Hanress objects.
We do basic setup here.

=back

=head1 SOURCE

The source code repository for Test2-Harness-Renderer-JUnit can be found at
F<https://github.com/CpanelInc/Test2-Harness-Renderer-JUnit>.

=head1 MAINTAINERS

=over 4

=item Todd Rinaldo Todd Rinaldo, C<< <toddr at cpanel.net> >>

=back

=head1 AUTHORS

=over 4

=item Todd Rinaldo, C<< <toddr at cpanel.net> >>

=back

=head1 COPYRIGHT

Copyright 2019 Todd Rinaldo<lt>toddr@cpanel.netE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
