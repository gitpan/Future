#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Builder::Tester;

use Future;
use Test::Future;

# pass
{
   test_out( "ok 1 - immediate Future" );

   my $ran_code;
   no_pending_futures {
      $ran_code++;
      Future->done(1,2,3);
   } 'immediate Future';

   test_test( "immediate Future passes" );
   ok( $ran_code, 'actually ran the code' );
}

# fail
{
   test_out( "not ok 1 - pending Future" );
   test_fail( +7 );
   test_err( "# The following Futures are still pending:" );
   test_err( qr/^# 0x[0-9a-f]+\n/ );
   test_err( qr/^# Writing heap dump to \S+\n/ ) if Test::Future::HAVE_DEVEL_MAT_DUMPER;

   no_pending_futures {
      Future->new;
   } 'pending Future';

   test_test( "pending Future fails" );
}

END {
   # Clean up Devel::MAT dumpfile
   my $pmat = $0;
   $pmat =~ s/\.t$/-1.pmat/;
   unlink $pmat if -f $pmat;
}

done_testing;
