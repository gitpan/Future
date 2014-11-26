#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Identity;

use Future;

{
   my $warnings;
   local $SIG{__WARN__} = sub { $warnings .= join "", @_ };

   my $f1 = Future->new;

   my $f2;
   my $fseq = $f1->and_then( sub { 
      identical( $_[0], $f1, 'and_then block passed $f1' );
      return $f2 = Future->new;
   } );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   $f1->done;

   $f2->done( results => "here" );

   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq->get returns results' );
   ok( length $warnings, '->and_then causes a warning' );
}

$SIG{__WARN__} = sub {};

# code dies
{
   my $f1 = Future->new;

   my $fseq = $f1->and_then( sub {
      die "It fails\n";
   } );

   ok( !defined exception { $f1->done }, 'exception not propagated from done call' );

   ok( $fseq->is_ready, '$fseq is ready after code exception' );
   is( scalar $fseq->failure, "It fails\n", '$fseq->failure after code exception' );
}

# immediately done
{
   my $f1 = Future->done;

   my $called = 0;
   my $fseq = $f1->and_then(
      sub { $called++; return $_[0] }
   );

   is( $called, 1, 'and_then block invoked immediately for already-done' );
   ok( $fseq->is_ready, '$fseq already ready for already-done' );
}

# immediately fail
{
   my $f1 = Future->fail("Failure\n");

   my $called = 0;
   my $fseq = $f1->and_then(
      sub { $called++; return $_[0] }
   );

   is( $called, 0, 'and_then block not invoked for already-failed' );
   ok( $fseq->is_ready, '$fseq already ready for already-failed' );
}

done_testing;
