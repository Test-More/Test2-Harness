requires "Carp" => "0";
requires "File::Find" => "0";
requires "File::Temp" => "0";
requires "Getopt::Long" => "2.36";
requires "IO::Handle" => "1.27";
requires "IPC::Open3" => "0";
requires "JSON::PP" => "0";
requires "List::Util" => "0";
requires "POSIX" => "0";
requires "Scalar::Util" => "0";
requires "Symbol" => "0";
requires "Term::ANSIColor" => "0";
requires "Test2" => "1.302071";
requires "Test2::AsyncSubtest" => "0.000013";
requires "Test2::Bundle::Extended" => "0.000063";
requires "Time::HiRes" => "0";
requires "perl" => "5.008001";
suggests "Cpanel::JSON::XS" => "0";
suggests "JSON::MaybeXS" => "0";

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "0";
};

on 'develop' => sub {
  requires "Test::Pod" => "1.41";
};
