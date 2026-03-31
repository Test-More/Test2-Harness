use Test2::V0 -target => 'App::Yath::Schema::DateTimeFormat';

# Pre-populate %INC so the require calls in DTF() succeed without the real modules.
BEGIN {
    for my $mod (qw/DateTime::Format::SQLite DateTime::Format::MySQL DateTime::Format::Pg/) {
        (my $file = $mod) =~ s{::}{/}g;
        $file .= '.pm';
        $INC{$file} //= 1;
    }
    package DateTime::Format::SQLite;
    package DateTime::Format::MySQL;
    package DateTime::Format::Pg;
    package main;
}

require App::Yath::Schema::DateTimeFormat;
my $DTF = \&App::Yath::Schema::DateTimeFormat::DTF;

# DTF() uses a lexical $DTF for memoization; it can only be called once
# effectively within a single process (the cache sticks). We test each
# driver in a subprocess so the cache starts fresh.

sub dtf_for {
    my ($loaded) = @_;
    my $result = `$^X -Ilib -e 'BEGIN { \$App::Yath::Schema::LOADED = q{$loaded}; my \%inc; for my \$m (qw/DateTime::Format::SQLite DateTime::Format::MySQL DateTime::Format::Pg/) { (my \$f = \$m) =~ s{::}{/}g; \$INC{"\$f.pm"} = 1 } } use App::Yath::Schema::DateTimeFormat qw/DTF/; print DTF()' 2>/dev/null`;
    chomp $result;
    return $result;
}

subtest "DTF dies when LOADED not set" => sub {
    local $App::Yath::Schema::LOADED = undef;
    ok(dies { $DTF->() }, "DTF dies when no schema is loaded");
};

subtest "DTF for SQLite (first call in process)" => sub {
    local $App::Yath::Schema::LOADED = 'SQLite';
    is($DTF->(), 'DateTime::Format::SQLite', "SQLite LOADED returns DateTime::Format::SQLite");
};

subtest "DTF memoizes result" => sub {
    # After the SQLite test above the cache is set; calling again returns the same value.
    is($DTF->(), $DTF->(), "DTF returns the same value on repeated calls");
};

subtest "DTF for MySQL (subprocess)" => sub {
    is(dtf_for('MySQL'), 'DateTime::Format::MySQL', "MySQL LOADED returns DateTime::Format::MySQL");
};

subtest "DTF for MariaDB (subprocess)" => sub {
    is(dtf_for('MariaDB'), 'DateTime::Format::MySQL', "MariaDB LOADED returns DateTime::Format::MySQL");
};

subtest "DTF for Percona (subprocess)" => sub {
    is(dtf_for('Percona'), 'DateTime::Format::MySQL', "Percona LOADED returns DateTime::Format::MySQL");
};

subtest "DTF for PostgreSQL (subprocess)" => sub {
    is(dtf_for('PostgreSQL'), 'DateTime::Format::Pg', "PostgreSQL LOADED returns DateTime::Format::Pg");
};

done_testing;
