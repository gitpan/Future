use strict;
use warnings;

use Module::Build;

# This version of Future contains an important bugfix around weak references
# in sequence Futures. Unfortunately, a lot of existing CPAN code is known to
# rely on this behaviour, and will break if this module is upgraded.
#
# Abort if any of the following modules are installed at versions less than
# the first known-working version. They must be updated before Future can be
# installed.
my %FIXED = (
   'IO::Async' => '0.62',
   'IO::Async::SSL' => '0.14',
   'Net::Async::CassandraCQL' => '0.11',
   'Net::Async::FTP' => '0.08',
   'Net::Async::HTTP' => '0.34',
   'Net::Async::WebSocket' => '0.08',
);

my $abort;
foreach my $module ( sort keys %FIXED ) {
   my $needsver = $FIXED{$module};
   ( my $modfile = "$module.pm" ) =~ s{::}{/}g;

   next unless eval { require $modfile };
   next if ( my $instver = $module->VERSION ) >= $needsver;

   print STDERR "Installing this version of Future will fix a bug that the following installed\n".
                "modules rely on. You must upgrade these modules to a later version before\n".
                "Future can be installed.\n\n" unless $abort;

   print STDERR "  * $module (installed $instver; need at least $needsver)\n";
   $abort++;
}

if( $abort ) {
   print STDERR "\n";

   grep { $_ eq "--force" } @ARGV or
      die "OS unsupported - please try again after upgrading the modules listed above\n".
          "\n".
          "Or run as  Build.PL --force  to ignore this and continue anyway\n";

   print STDERR "******\n\nGoing ahead anyway as --force was given; the above modules -will- now be broken\n\n******\n";
   @ARGV = grep { $_ ne "--force" } @ARGV;
}

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
      'Carp' => '1.25', # new message format with trailing period
   },
   auto_configure_requires => 0, # Don't add M::B to configure_requires
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
);

$build->create_build_script;
