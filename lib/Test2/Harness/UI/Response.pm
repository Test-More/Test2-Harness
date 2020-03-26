package Test2::Harness::UI::Response;
use strict;
use warnings;

our $VERSION = '0.000028';

use Carp qw/croak/;
use Time::HiRes qw/sleep/;
use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'Plack::Response';

use Importer Importer => 'import';
our %EXPORT_ANON = (
    resp  => sub { __PACKAGE__->new(@_) },
    error => sub { __PACKAGE__->error(@_) },
);

my %DEFAULT_ERRORS = (
    204 => 'No Content',
    205 => 'Reset Content',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    402 => 'Payment Required',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    406 => 'Not Acceptable',
    407 => 'Proxy Authentication Required',
    408 => 'Request Timeout',
    409 => 'Conflict',
    410 => 'Gone',
    411 => 'Length Required',
    412 => 'Precondition Failed',
    413 => 'Payload Too Large',
    414 => 'URI Too Long',
    415 => 'Unsupported Media Type',
    416 => 'Range Not Satisfiable',
    417 => 'Expectation Failed',
    418 => 'I\'m a teapot',
    421 => 'Misdirected Request',
    422 => 'Unprocessable Entity',
    423 => 'Locked',
    424 => 'Failed Dependency',
    426 => 'Upgrade Required',
    428 => 'Precondition Required',
    429 => 'Too Many Requests',
    431 => 'Request Header Fields Too Large',
    451 => 'Unavailable For Legal Reasons',
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Timeout',
    505 => 'HTTP Version Not Supported',
    506 => 'Variant Also Negotiates',
    507 => 'Insufficient Storage',
    508 => 'Loop Detected',
    510 => 'Not Extended',
    511 => 'Network Authentication Required',
);

BEGIN {
    for my $accessor (qw/no_wrap is_error errors messages title css js raw_body/) {
        no strict 'refs';
        *{"$accessor"} = sub { $_[0]->{$accessor} = $_[1] if @_ > 1; $_[0]->{$accessor} };
    }
}

sub stream {
    my $self = shift;
    if (@_) {
        my %params = @_;

        my $env = $params{env} or croak "'env' is a required parameter";

        my ($done, $fetch);
        if(my $rs = $params{resultset}) {
            my $json = Test2::Harness::Util::JSON::JSON()->new->utf8(0)->convert_blessed(1)->allow_nonref(1);
            my $go = 1;
            $done = sub { !$go };
            $fetch = sub {
                $go = $rs->next() or return;
                my $data = $go;
                if(my $meth = $params{data_method}) {
                    $data = $go->$meth();
                }
                my $out = $json->encode($data) . "\n";
                return $out;
            };
        }
        else {
            $done  = $params{done} or croak "'done' is a required parameter";
            $fetch = $params{fetch} or croak "'fetch' is a required parameter";
        }

        my $wait = $params{wait} || 0.2;
        my $cleanup = $params{cleanup};

        my $ct = $params{content_type} || $params{'content-type'} || $params{'Content-Type'} or croak "'content_type' is a required attribute";

        $self->{stream} = sub {
            my $responder = shift;
            my $writer = $responder->([200, ['Content-Type' => $ct]]);

            my $end = 0;
            while (!$end) {
                $end = $done->();

                last unless $env->{'psgix.io'}->connected;

                my $seen = 0;
                for my $item ($fetch->()) {
                    $writer->write($item);
                    $seen++;
                }

                sleep $wait unless $seen;
            }

            $cleanup->() if $cleanup;
            $writer->close;
        };
    }

    return $self->{stream};
}

sub error {
    my $class = shift;
    my ($code, $msg) = @_;

    $msg ||= $DEFAULT_ERRORS{$code} || 'Error';

    my $self = $class->new($code);
    $self->body($msg);
    $self->is_error(1);
    $self->title($msg ? "error: $code - $msg" : "error: $code");

    return $self;
}

*add_message = \&add_msg;
sub add_msg {
    my $self = shift;

    push @{$self->{messages} ||= []} => @_;

    return;
}

sub add_error {
    my $self = shift;

    push @{$self->{errors} ||= []} => @_;

    return;
}

sub as_json {
    my $self = shift;
    my (%inject) = @_;
    $self->content_type('application/json');

    my $data = {
        %inject,
        messages => $self->{messages},
        errors   => $self->{errors},
    };

    $self->raw_body($data);
}

sub add_css {
    my $self = shift;

    push @{$self->{css} ||= []} => @_;

    return;
}

sub add_js {
    my $self = shift;

    push @{$self->{js} ||= []} => @_;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Response - Web Response

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

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
