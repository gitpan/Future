# Note: this file was auto-generated by Module::Build::Compat version 0.4210
require 5.008;
use ExtUtils::MakeMaker;
WriteMakefile
(
  'NAME' => 'Future',
  'VERSION_FROM' => 'lib/Future.pm',
  'PREREQ_PM' => {
                   'Carp' => '1.25',
                   'Test::Builder::Module' => 0,
                   'Test::Fatal' => 0,
                   'Test::Identity' => 0,
                   'Test::More' => '0.88',
                   'Test::Refcount' => 0,
                   'Time::HiRes' => 0
                 },
  'INSTALLDIRS' => 'site',
  'EXE_FILES' => [],
  'PL_FILES' => {}
)
;
