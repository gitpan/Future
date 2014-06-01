#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Identity;

use Future;

# First failure
{
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
}

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

# Void context raises a warning
{
   my $warnings;
   local $SIG{__WARN__} = sub { $warnings .= $_[0]; };

   Future->done->or_else(
      sub { Future->new }
   );
   like( $warnings,
         qr/^Calling ->or_else in void context at /,
         'Warning in void context' );
}

# Non-Future return raises exception
{
   my $f1 = Future->new;

   my $file = __FILE__;
   my $line = __LINE__+1;
   my $fseq = $f1->or_else( sub {} );

   like( exception { $f1->fail(1) },
       qr/^Expected __ANON__\(\Q$file\E line $line\) to return a Future/,
       'Exception from non-Future return' );
}

done_testing;
