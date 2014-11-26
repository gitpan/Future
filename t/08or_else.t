#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Identity;

use Future;

# First failure
{
   my $warnings;
   local $SIG{__WARN__} = sub { $warnings .= join "", @_ };

   my $f1 = Future->new;

   my $f2;
   my $fseq = $f1->or_else( sub { 
      identical( $_[0], $f1, 'or_else block passed $f1' );
      return $f2 = Future->new;
   } );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   $f1->fail( "Broken\n" );

   $f2->done( results => "here" );

   ok( $fseq->is_ready, '$fseq is done after $f2 done' );
   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq->get returns results' );
   ok( length $warnings, '->or_else causes a warning' );
}

$SIG{__WARN__} = sub {};

# code dies
{
   my $f1 = Future->new;

   my $fseq = $f1->or_else( sub {
      die "It fails\n";
   } );

   ok( !defined exception { $f1->fail("bork") }, 'exception not propagated from fail call' );

   ok( $fseq->is_ready, '$fseq is ready after code exception' );
   is( scalar $fseq->failure, "It fails\n", '$fseq->failure after code exception' );
}

# immediately fail
{
   my $f1 = Future->fail("Failure\n");

   my $called = 0;
   my $fseq = $f1->or_else(
      sub { $called++; return $_[0] }
   );

   is( $called, 1, 'or_else block invoked immediately for already-fail' );
   ok( $fseq->is_ready, '$fseq already ready for already-fail' );
}

# immediately done
{
   my $f1 = Future->done("Result");

   my $called = 0;
   my $fseq = $f1->or_else(
      sub { $called++; return $_[0] }
   );

   is( $called, 0, 'or_else block not invoked for already-done' );
   ok( $fseq->is_ready, '$fseq already ready for already-done' );
}

done_testing;
