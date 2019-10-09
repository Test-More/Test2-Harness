use Test2::V0 -target => 'App::Yath::Option';


done_testing;

__END__


my %TYPES = (
    b => 1,
    c => 1,
    s => 1,
    m => 1,
    d => 1,
    D => 1,
    h => 1,
    H => 1,
);

my %LONG_TO_SHORT_TYPES = (
    bool    => 'b',
    boolean => 'b',

    count    => 'c',
    counter  => 'c',
    counting => 'c',

    scalar => 's',
    string => 's',
    number => 's',

    multi    => 'm',
    multiple => 'm',
    list     => 'm',
    array    => 'm',

    default => 'd',
    def     => 'd',

    'multi-def'        => 'D',
    'multiple-default' => 'D',
    'list-default'     => 'D',
    'array-default'    => 'D',

    'hash' => 'h',
    'hash-list' => 'H',
);

my %TAKES_ARG = (s => 1, m => 1, h => 1, H => 1);
sub takes_arg { $TAKES_ARG{$_[0]->{+TYPE}} }

my %ALLOWS_ARG = (d => 1, D => 1);
sub allows_arg { $ALLOWS_ARG{$_[0]->{+TYPE}} || $TAKES_ARG{$_[0]->{+TYPE} } }

sub init {
    my $self = shift;

    confess "You must specify 'title' or both 'field' and 'name'"
        unless $self->{+TITLE} || ($self->{+FIELD} && $self->{+NAME});

    confess "The 'prefix' attribute is required"
        unless $self->{+PREFIX};

    confess "The 'alt' attribute must be an array-ref"
        if $self->{+ALT} && ref($self->{+ALT}) ne 'ARRAY';

    if (my $title = $self->{+TITLE}) {
        $self->{+FIELD} //= $title;
        $self->{+NAME} //= ($self->{+FROM_PLUGIN} && $self->{+PREFIX}) ? "$self->{+PREFIX}-$title" : $title;
    }

    $self->{+FIELD} =~ s/-/_/g;
    $self->{+NAME}  =~ s/_/-/g;

    if (my $class = $self->{+BUILDS}) {
        confess "class '$class' does not have a '$self->{+FIELD}' method"
            unless $class->can($self->{+FIELD});
    }

    $self->{+TYPE} //= 'b';
    $self->{+TYPE} = $LONG_TO_SHORT_TYPES{$self->{+TYPE}} // $self->{+TYPE} if length($self->{+TYPE}) > 1;
    confess "Invalid type '$self->{+TYPE}'" unless $TYPES{$self->{+TYPE}};

    if (my $def = $self->{+DEFAULT}) {
        my $ref = ref($def);
        confess "'default' must be a simple scalar, or a coderef, got a '$ref'" if $ref && $ref ne 'CODE';
    }

    for my $key (NORMALIZE(), ACTION(), POST_PROCESS()) {
        my $val = $self->{$key} or next;
        my $ref = ref($val) || 'not a ref';
        next if $ref eq 'CODE';
        confess "'$key' must be undef, or a coderef, got '$ref'";
    }

    $self->{+TRACE}       //= [caller(1)];
    $self->{+CATEGORY}    //= 'NO CATEGORY - FIX ME';
    $self->{+DESCRIPTION} //= 'NO DESCRIPTION - FIX ME';

    $self->{+POST_PROCESS_WEIGHT} //= 0;

    for my $key (sort keys %$self) {
        confess "'$key' is not a valid option attribute"
            unless $self->can(uc($key));
    }

    return $self;
}

sub long_args {
    my $self = shift;

    return ($self->{+NAME}, @{$self->{+ALT} || []});
}

sub option_slot {
    my $self = shift;
    my ($settings) = @_;

    confess "A settings instance is required" unless $settings;
    return $settings->define_prefix($self->{+PREFIX})->vivify_field($self->{+FIELD});
}

sub get_default {
    my $self = shift;

    if (defined $self->{+DEFAULT}) {
        my $def = $self->{+DEFAULT};

        return $self->$def() if ref($def);

        return $def;
    }

    return 0
        if $self->{+TYPE} eq 'c'
        || $self->{+TYPE} eq 'b';

    return []
        if $self->{+TYPE} eq 'm'
        || $self->{+TYPE} eq 'D';

    return {}
        if $self->{+TYPE} eq 'h'
        || $self->{+TYPE} eq 'H';

    return undef;
}

sub get_normalized {
    my $self = shift;
    my ($raw) = @_;

    return $self->{+NORMALIZE}->($raw)
        if $self->{+NORMALIZE};

    return $raw ? 1 : 0
        if $self->{+TYPE} eq 'b';

    if (lc($self->{+TYPE}) eq 'h') {
        my ($key, $val) = split /=/, $raw, 2;

        if ($self->{+TYPE} eq 'H') {
            $val //= '';
            $val = [split /,/, $val];
            return [$key, $val];
        }

        return [$key, $val // 1];
    }

    return $raw;
}

my %HANDLERS = (
    c => sub { ${$_[0]}++ },
    m => sub { push @{${$_[0]} //= []} => $_[1] },
    D => sub { push @{${$_[0]} //= []} => $_[1] },
    h => sub {
        my $hash = ${$_[0]} //= {};
        my $key = $_[1]->[0];
        my $val = $_[1]->[1];

        push @{$hash->{'@'} //= []} => $key unless $hash->{$key};
        $hash->{$key} = $val;
    },
    H => sub {
        my $hash = ${$_[0]} //= {};
        my $key = $_[1]->[0];
        my $vals = $_[1]->[1];

        push @{$hash->{'@'} //= []} => $key unless $hash->{$key};
        push @{$hash->{$key} //= []} => @$vals;
    },
);

sub handle {
    my $self = shift;
    my ($raw, $settings) = @_;

    confess "A settings instance is required" unless $settings;

    my $slot = $self->option_slot($settings);
    my $norm = $self->get_normalized($raw);

    my $handler = $HANDLERS{$self->{+TYPE}} //= sub { ${$_[0]} = $_[1] };

    return $self->{+ACTION}->($self->{+PREFIX}, $self->{+FIELD}, $raw, $norm, $slot, $settings, $handler)
        if $self->{+ACTION};

    return $handler->($slot, $norm);
}

sub handle_negation {
    my $self = shift;
    my ($settings) = @_;

    confess "A settings instance is required" unless $settings;

    my $slot = $self->option_slot($settings);

    return $self->{+NEGATE}->($self->{+PREFIX}, $self->{+FIELD}, $slot, $settings)
        if $self->{+NEGATE};

    return $$slot = 0
        if $self->{+TYPE} eq 'b'
        || $self->{+TYPE} eq 'c';

    return @{$$slot //= []} = ()
        if $self->{+TYPE} eq 'm'
        || $self->{+TYPE} eq 'D';

    return @{$$slot //= {}} = ()
        if $self->{+TYPE} eq 'h'
        || $self->{+TYPE} eq 'H';

    return $$slot = undef;
}

sub trace_string {
    my $self  = shift;
    my $trace = $self->{+TRACE} or return "[UNKNOWN]";
    return "$trace->[1] line $trace->[2]";
}

my %TYPE_LONG_ARGS = (
    b => [''],
    c => [''],
    s => [' ARG', '=ARG'],
    m => [' ARG', '=ARG'],
    d => ['[=ARG]'],
    D => ['[=ARG]'],
    h => [' KEY=VAL', '=KEY=VAL'],
    H => [' KEY=VAL1,VAL2,...', '=KEY=VAL1,VAL2,...'],
);

my %TYPE_SHORT_ARGS = (
    b => [''],
    c => [''],
    s => [' ARG', '=ARG'],
    m => [' ARG', '=ARG'],
    d => ['[=ARG]', '[ARG]'],
    D => ['[=ARG]', '[ARG]'],
    h => [' KEY=VAL', '=KEY=VAL'],
    H => [' KEY=VAL1,VAL2,...', '=KEY=VAL1,VAL2,...'],
);

my %TYPE_NOTES = (
    'c' => "Can be specified multiple times",
    'm' => "Can be specified multiple times",
    'D' => "Can be specified multiple times",
    'h' => "Can be specified multiple times",
    'H' => "Can be specified multiple times. If the same key is listed multiple times the value lists will be appended together.",
);

sub cli_docs {
    my $self = shift;

    my @forms = (map { "--$self->{+NAME}$_" } @{$self->{+LONG_EXAMPLES}  || $TYPE_LONG_ARGS{$self->{+TYPE}}});
    push @forms => map { "-$self->{+SHORT}$_" } @{$self->{+SHORT_EXAMPLES} || $TYPE_SHORT_ARGS{$self->{+TYPE}}}
        if $self->{+SHORT};
    push @forms => "--no-$self->{+NAME}";

    my @out;

    require App::Yath::Util;
    require Test2::Util::Term;

    my $width = Test2::Util::Term::term_size() - 20;
    $width = 80 unless $width && $width >= 80;

    push @out => App::Yath::Util::fit_to_width($width, ",  ", \@forms);

    my $desc = App::Yath::Util::fit_to_width($width, " ", $self->{+DESCRIPTION});
    $desc =~ s/^/  /gm;
    push @out => $desc;

    push @out => "\n  Note: " . $TYPE_NOTES{$self->{+TYPE}} if $TYPE_NOTES{$self->{+TYPE}};

    return join "\n" => @out;
}

sub pod_docs {
    my $self = shift;

    my @forms = (map { "--$self->{+NAME}$_" } @{$self->{+LONG_EXAMPLES}  || $TYPE_LONG_ARGS{$self->{+TYPE}}});
    push @forms => map { "-$self->{+SHORT}$_" } @{$self->{+SHORT_EXAMPLES} || $TYPE_SHORT_ARGS{$self->{+TYPE}}}
        if $self->{+SHORT};
    push @forms => "--no-$self->{+NAME}";

    my @out = map { "=item $_" } @forms;

    push @out => $self->{+DESCRIPTION};

    push @out => $TYPE_NOTES{$self->{+TYPE}} if $TYPE_NOTES{$self->{+TYPE}};

    return join "\n\n" => @out;
}
