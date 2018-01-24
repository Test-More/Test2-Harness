package Test2::Harness::UI::Import;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::UI::Util::HashBase qw/-schema/;

sub init {
    my $self = shift;

    croak "'schema' is a required attribute"
        unless $self->{+SCHEMA};
}

sub _fail {
    my $self = shift;
    my ($msg, %params) = @_;

    my $out = {%params};
    push @{$out->{errors}} => $msg;

    return $out;
}

sub import_events {
    my $self = shift;

    my $schema = $self->{+SCHEMA};
    $schema->txn_begin;

    my $out;
    my $ok = eval { $out = $self->_import_events(@_); 1 };
    my $err = $@;

    if (!$ok) {
        warn $@;
        $schema->txn_rollback;
        return { errors => ['Internal Error'], internal_error => 1 };
    }

    if ($out->{errors} && @{$out->{errors}}) {
        $schema->txn_rollback;
    }
    else {
        $schema->txn_commit;
    }

    return $out;
}

sub _import_events {
    my $self = shift;
    my ($params) = @_;

    $params = decode_json($params) unless ref $params;

    my $schema = $self->{+SCHEMA};

    # Verify credentials
    my $username = $params->{username} or return $self->_fail("No username specified");
    my $password = $params->{password} or return $self->_fail("No password specified");
    my $user = $schema->resultset('User')->find({username => $username});
    return $self->_fail("Incorrect credentials")
        unless $user && $user->verify_password($password);

    # Verify or create stream
    my $stream_id = $params->{stream};
    my $stream;
    if ($stream_id) {
        $stream = $schema->resultset('Stream')->find({user_id => $user->user_id, stream_id => $stream_id});
        return $self->_fail("Invalid stream") unless $stream;
    }
    else {
        $stream = $schema->resultset('Stream')->create({user_id => $user->user_id});
    }

    my $cnt = 0;
    for my $event (@{$params->{events}}) {
        my $error = $self->import_event($stream->stream_id, $event);
        return $self->_fail("error processing event number $cnt: $error") if $error;
        $cnt++;
    }

    return {success => 1, events_added => $cnt};
}

sub import_event {
    my $self = shift;
    my ($stream_id, $event_data) = @_;

    my $schema = $self->{+SCHEMA};

    my $run_id = $event_data->{run_id};
    return "no run_id provided" unless defined $run_id;
    my $run = $schema->resultset('Run')->find_or_create({stream_id => $stream_id, run_id => $run_id})
        or die "Unable to find/add run: $run_id";

    my $job_id = $event_data->{job_id};
    return "no job_id provided" unless defined $job_id;
    my $job = $schema->resultset('Job')->find_or_create({job_id => $job_id, run_ui_id => $run->run_ui_id});

    my $event = $schema->resultset('Event')->create(
        {
            job_ui_id => $job->job_ui_id,
            stamp     => $event_data->{stamp},
            event_id  => $event_data->{event_id},
            stream_id => $event_data->{stream_id},
        }
    );
    die "Could not create event" unless $event;

    my $facets = $event_data->{facet_data} || {};
    for my $facet_name (keys %$facets) {
        my $vals = $facets->{$facet_name} or next;
        $vals = [$vals] unless ref($vals) eq 'ARRAY';

        my $cnt = 0;
        for my $val (@$vals) {
            my $facet = $schema->resultset('Facet')->create({
                event_ui_id => $event->event_ui_id,
                facet_name => $facet_name,
                facet_value => encode_json($val),
            });
            die "Could not add facet '$facet_name' number $cnt" unless $facet;
            $cnt++;
        }
    }

    return;
}

1;

__END__

CREATE TABLE facets (
    facet_ui_id     BIGSERIAL   PRIMARY KEY,
    event_ui_id     BIGINT      NOT NULL REFERENCES events(event_ui_id),

    facet_type      facet_type  NOT NULL DEFAULT 'other',

    facet_name      TEXT        NOT NULL,
    facet_value     JSONB       NOT NULL
);

$VAR1 = [
          {
            'event_id' => 'harness-1',
            'run_id' => 1516735347,
            'job_id' => 0,
            'stamp' => '1516735347.64279',
            'stream_id' => 'harness',
            'facet_data' => {
                              'harness' => {
                                             'job_id' => 0,
                                             'run_id' => 1516735347,
                                             'event_id' => 'harness-1'
                                           },
                              'harness_run' => {
                                                 'libs' => [
                                                             '/home/exodist/projects/Test2/Test2-Harness/lib',
                                                             '/home/exodist/projects/Test2/Test2-Harness/lib',
                                                             '/home/exodist/projects/Test2/Test2-Harness/blib/lib',
                                                             '/home/exodist/projects/Test2/Test2-Harness/blib/arch'
                                                           ],
                                                 'use_stream' => 1,
                                                 'load' => undef,
                                                 'switches' => [],
                                                 'verbose' => 0,
                                                 'exclude_patterns' => [],
                                                 'input' => undef,
                                                 'unsafe_inc' => 1,
                                                 'env_vars' => {
                                                                 'T2_HARNESS_VERSION' => '0.001049',
                                                                 'T2_HARNESS_RUN_ID' => 1516735347,
                                                                 'HARNESS_JOBS' => 1,
                                                                 'T2_HARNESS_IS_VERBOSE' => 0,
                                                                 'T2_HARNESS_JOBS' => 1,
                                                                 'HARNESS_ACTIVE' => 1,
                                                                 'HARNESS_IS_VERBOSE' => 0,
                                                                 'T2_HARNESS_ACTIVE' => 1,
                                                                 'PERL_USE_UNSAFE_INC' => 1,
                                                                 'HARNESS_VERSION' => 'Test2-Harness-0.001049'
                                                               },
                                                 'tlib' => 0,
                                                 'exclude_files' => {},
                                                 'blib' => 1,
                                                 'args' => [],
                                                 'load_import' => undef,
                                                 'finite' => 1,
                                                 'job_count' => 1,
                                                 'cover' => undef,
                                                 'run_id' => 1516735347,
                                                 'no_long' => undef,
                                                 'preload' => undef,
                                                 'lib' => 1,
                                                 'plugins' => [],
                                                 'search' => [
                                                               't2/simple.t'
                                                             ],
                                                 'dummy' => 0,
                                                 'times' => undef,
                                                 'use_fork' => 1
                                               },
                              'about' => {
                                           'no_display' => 1
                                         }
                            }
          },
          {
            'event_id' => 'harness-2',
            'job_id' => 1,
            'run_id' => 1516735347,
            'stamp' => '1516735347.80549',
            'times' => [
                         '0.26',
                         '0.05',
                         '0',
                         '0'
                       ],
            'stream_id' => 'harness',
            'facet_data' => {
                              'harness_job_launch' => {
                                                        'stamp' => '1516735347.80548'
                                                      },
                              'harness' => {
                                             'run_id' => 1516735347,
                                             'job_id' => 1,
                                             'event_id' => 'harness-2'
                                           },
                              'harness_job' => {
                                                 'event_timeout' => undef,
                                                 'use_timeout' => 1,
                                                 'args' => [],
                                                 'load_import' => [],
                                                 'use_fork' => 1,
                                                 'times' => undef,
                                                 'category' => 'general',
                                                 'job_id' => 1,
                                                 'preload' => [],
                                                 'switches' => [
                                                                 '-w'
                                                               ],
                                                 'postexit_timeout' => undef,
                                                 'load' => [],
                                                 'stage' => 'default',
                                                 'use_preload' => 1,
                                                 'use_stream' => 1,
                                                 'libs' => [
                                                             '/home/exodist/projects/Test2/Test2-Harness/lib',
                                                             '/home/exodist/projects/Test2/Test2-Harness/lib',
                                                             '/home/exodist/projects/Test2/Test2-Harness/blib/lib',
                                                             '/home/exodist/projects/Test2/Test2-Harness/blib/arch'
                                                           ],
                                                 'env_vars' => {
                                                                 'PERL5LIB' => '/home/exodist/projects/Test2/Test2-Harness/lib:/home/exodist/projects/Test2/Test2-Harness/lib:/home/exodist/projects/Test2/Test2-Harness/blib/lib:/home/exodist/projects/Test2/Test2-Harness/blib/arch',
                                                                 'HARNESS_VERSION' => 'Test2-Harness-0.001049',
                                                                 'HARNESS_IS_VERBOSE' => 0,
                                                                 'T2_HARNESS_ACTIVE' => 1,
                                                                 'PERL_USE_UNSAFE_INC' => undef,
                                                                 'T2_HARNESS_RUN_ID' => 1516735347,
                                                                 'T2_HARNESS_JOBS' => 1,
                                                                 'HARNESS_JOBS' => 1,
                                                                 'T2_HARNESS_IS_VERBOSE' => 0,
                                                                 'TMPDIR' => '/tmp/yath-test-2427-uSdYJFoi/1/tmp',
                                                                 'HARNESS_ACTIVE' => 1,
                                                                 'T2_HARNESS_VERSION' => '0.001049',
                                                                 'TEMPDIR' => '/tmp/yath-test-2427-uSdYJFoi/1/tmp'
                                                               },
                                                 'stamp' => '1516735347.64107',
                                                 'input' => '',
                                                 'pid' => 2429,
                                                 'file' => '/home/exodist/projects/Test2/Test2-Harness/t2/simple.t'
                                               }
                            }
          },
          {
            'event_id' => 'start',
            'job_id' => 1,
            'run_id' => 1516735347,
            'stamp' => '1516735347.80138',
            'facet_data' => {
                              'harness' => {
                                             'run_id' => 1516735347,
                                             'job_id' => 1,
                                             'event_id' => 'start'
                                           },
                              'harness_job_start' => {
                                                       'stamp' => '1516735347.80138',
                                                       'file' => '/home/exodist/projects/Test2/Test2-Harness/t2/simple.t',
                                                       'details' => 'Job 1 started at 1516735347.80138',
                                                       'job_id' => 1
                                                     }
                            }
          },
          {
            'stamp' => '1516735347.91006',
            'times' => [
                         '0.07',
                         '0',
                         '0',
                         '0'
                       ],
            'facet_data' => {
                              'control' => {
                                             'encoding' => 'utf8'
                                           },
                              'harness' => {
                                             'run_id' => 1516735347,
                                             'job_id' => 1,
                                             'event_id' => 'event-1'
                                           }
                            },
            'stream_id' => 1,
            'assert_count' => undef,
            'event_id' => 'event-1',
            'run_id' => 1516735347,
            'job_id' => 1
          },
          {
            'stream_id' => 2,
            'facet_data' => {
                              'assert' => {
                                            'pass' => 1,
                                            'details' => 'pass',
                                            'no_debug' => 1
                                          },
                              'about' => {
                                           'package' => 'Test2::Event::Ok'
                                         },
                              'control' => {},
                              'trace' => {
                                           'tid' => 0,
                                           'pid' => 2429,
                                           'nested' => 0,
                                           'cid' => 'C1',
                                           'hid' => '2429~0~1',
                                           'buffered' => 0,
                                           'frame' => [
                                                        'main',
                                                        't2/simple.t',
                                                        4,
                                                        'Test2::Tools::Basic::ok'
                                                      ]
                                         },
                              'harness' => {
                                             'run_id' => 1516735347,
                                             'job_id' => 1,
                                             'event_id' => 'event-2'
                                           }
                            },
            'stamp' => '1516735347.91021',
            'times' => [
                         '0.07',
                         '0',
                         '0',
                         '0'
                       ],
            'job_id' => 1,
            'run_id' => 1516735347,
            'event_id' => 'event-2',
            'assert_count' => 1
          },
          {
            'event_id' => 'event-3',
            'assert_count' => 1,
            'job_id' => 1,
            'run_id' => 1516735347,
            'stamp' => '1516735347.91032',
            'times' => [
                         '0.07',
                         '0',
                         '0',
                         '0'
                       ],
            'facet_data' => {
                              'trace' => {
                                           'tid' => 0,
                                           'pid' => 2429,
                                           'nested' => 0,
                                           'cid' => 'C2',
                                           'buffered' => 0,
                                           'hid' => '2429~0~1',
                                           'frame' => [
                                                        'main',
                                                        't2/simple.t',
                                                        5,
                                                        'Test2::Tools::Basic::done_testing'
                                                      ]
                                         },
                              'plan' => {
                                          'count' => 1
                                        },
                              'harness' => {
                                             'run_id' => 1516735347,
                                             'job_id' => 1,
                                             'event_id' => 'event-3'
                                           },
                              'about' => {
                                           'package' => 'Test2::Event::Plan'
                                         },
                              'control' => {
                                             'terminate' => undef
                                           }
                            },
            'stream_id' => 3
          },
          {
            'event_id' => 'exit',
            'run_id' => 1516735347,
            'job_id' => 1,
            'facet_data' => {
                              'harness_job_exit' => {
                                                      'exit' => '0',
                                                      'stdout' => 'T2-HARNESS-ESYNC: 1
T2-HARNESS-ESYNC: 2
T2-HARNESS-ESYNC: 3
',
                                                      'stderr' => 'T2-HARNESS-ESYNC: 1
T2-HARNESS-ESYNC: 2
T2-HARNESS-ESYNC: 3
',
                                                      'file' => '/home/exodist/projects/Test2/Test2-Harness/t2/simple.t',
                                                      'details' => 'Test script exited 0',
                                                      'job_id' => 1
                                                    },
                              'harness' => {
                                             'event_id' => 'exit',
                                             'job_id' => 1,
                                             'run_id' => 1516735347
                                           }
                            }
          },
          {
            'event_id' => 'harness-3',
            'job_id' => 1,
            'run_id' => 1516735347,
            'times' => [
                         '0.26',
                         '0.05',
                         '0.29',
                         '0.06'
                       ],
            'stamp' => '1516735347.92922',
            'stream_id' => 'harness',
            'facet_data' => {
                              'harness_job_end' => {
                                                     'stamp' => '1516735347.92922'
                                                   },
                              'harness' => {
                                             'event_id' => 'harness-3',
                                             'run_id' => 1516735347,
                                             'job_id' => 1
                                           }
                            }
          }
        ];
