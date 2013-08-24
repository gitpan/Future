#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;

use Future;

# then success
{
   my $f1 = Future->new;

   my $fdone;
   my $fseq = $f1->then(
      sub {
         is( $_[0], "f1 result", 'then done block passed result of $f1' );
         return $fdone = Future->new;
      }
   );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   ok( !$fdone, '$fdone not yet defined before $f1 done' );

   $f1->done( "f1 result" );

   ok( defined $fdone, '$fdone now defined after $f1 done' );

   ok( !$fseq->is_ready, '$fseq not yet done before $fdone done' );

   $fdone->done( results => "here" );

   ok( $fseq->is_ready, '$fseq is done after $fdone done' );
   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq->get returns results' );
}

# else failure
{
   my $f1 = Future->new;

   my $ffail;
   my $fseq = $f1->else(
      sub {
         is( $_[0], "f1 failure\n", 'then fail block passed result of $f1' );
         return $ffail = Future->new;
      }
   );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   ok( !$ffail, '$ffail not yet defined before $f1 fails' );

   $f1->fail( "f1 failure\n" );

   ok( defined $ffail, '$ffail now defined after $f1 fails' );

   ok( !$fseq->is_ready, '$fseq not yet done before $ffail done' );

   $ffail->done( results => "here" );

   ok( $fseq->is_ready, '$fseq is done after $ffail done' );
   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq->get returns results' );
}

# done fallthrough
{
   my $f1 = Future->new;
   my $fseq = $f1->then;

   $f1->done( "fallthrough result" );

   ok( $fseq->is_ready, '$fseq is ready' );
   is( scalar $fseq->get, "fallthrough result", '->then done fallthrough' );
}

# fail fallthrough
{
   my $f1 = Future->new;
   my $fseq = $f1->then;

   $f1->fail( "fallthrough failure\n" );

   ok( $fseq->is_ready, '$fseq is ready' );
   is( scalar $fseq->failure, "fallthrough failure\n", '->then fail fallthrough' );
}

# then cancel
{
   my $f1 = Future->new;
   my $fseq = $f1->then( sub { die "then done of cancelled Future should not be invoked" } );

   $fseq->cancel;

   ok( $f1->is_cancelled, '$f1 is cancelled by $fseq cancel' );

   $f1 = Future->new;
   my $f2;
   $fseq = $f1->then( sub { return $f2 = Future->new } );

   $f1->done;
   $fseq->cancel;

   ok( $f2->is_cancelled, '$f2 cancelled by $fseq cancel' );
}

# else cancel
{
   my $f1 = Future->new;
   my $fseq = $f1->else( sub { die "else of cancelled Future should not be invoked" } );

   $fseq->cancel;

   ok( $f1->is_cancelled, '$f1 is cancelled by $fseq cancel' );

   $f1 = Future->new;
   my $f2;
   $fseq = $f1->else( sub { return $f2 = Future->new } );

   $f1->fail( "A failure\n" );
   $fseq->cancel;

   ok( $f2->is_cancelled, '$f2 cancelled by $fseq cancel' );
}

# Void context raises a warning
{
   my $warnings;
   local $SIG{__WARN__} = sub { $warnings .= $_[0]; };

   Future->new->done->then(
      sub { Future->new }
   );
   like( $warnings,
         qr/^Calling ->then in void context /,
         'Warning in void context' );

   undef $warnings;
   Future->new->done->else(
      sub { Future->new }
   );
   like( $warnings,
         qr/^Calling ->else in void context /,
         'Warning in void context' );
}

# Non-Future return raises exception
{
   my $f1 = Future->new;

   my $file = __FILE__;
   my $line = __LINE__+1;
   my $fseq = $f1->then( sub {} );

   like( exception { $f1->done },
       qr/^Expected code to return a Future in then at \Q$file\E line $line\.?/,
       'Exception from non-Future return' );

   $f1 = Future->new;
   $file = __FILE__;
   $line = __LINE__+1;
   $fseq = $f1->else( sub {} );

   like( exception { $f1->fail( "failed\n" ) },
       qr/^Expected code to return a Future in else at \Q$file\E line $line\.?/,
       'Exception from non-Future return' );
}

done_testing;
