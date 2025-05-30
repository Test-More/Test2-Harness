use Test2::V0;

plan tests => 1;

sub checks_exit_code {
  diag $?;

  if ( $? != 0 ) {
    die 'exit code is not 0';
  }
}

ok(lives { checks_exit_code() }, 'exit code OK');

done_testing;
