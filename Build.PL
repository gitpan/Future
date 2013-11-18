use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
   module_name => 'Future',
   build_requires => {
      'Test::Identity' => 0,
      'Test::Fatal' => 0,
      'Test::More' => '0.88', # done_testing
      'Test::Refcount' => 0,
   },
   requires => {
      'perl' => '5.008', # fails on 5.6 smokers; no idea why
   },
   auto_configure_requires => 0, # Don't add M::B to configure_requires
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
);

$build->create_build_script;
