my $out = <<EOT;
ok 1 - foo
ok 2 - bar
ok 3 - baz
EOT

print $out;
print $out unless $ENV{FAILURE_DO_PASS};

print "1.." . ($ENV{FAILURE_DO_PASS} ? 3 : 6) . "\n";
