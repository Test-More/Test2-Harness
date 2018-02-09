package Test2::Harness::UI::Response;
use strict;
use warnings;

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
    for my $accessor (qw/no_wrap is_error errors messages title css js/) {
        no strict 'refs';
        *{"$accessor"} = sub { $_[0]->{$accessor} = $_[1] if @_ > 1; $_[0]->{$accessor} };
    }
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
