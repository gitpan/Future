#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

use Future;
use Future::Utils qw( fmap_void );

# fmap_void from ARRAY, no concurrency
{
   my @subf;
   my $future = fmap_void {
      return $subf[$_[0]] = Future->new
   } foreach => [ 0 .. 2 ];

   ok( defined $future, '$future defined for fmap non-concurrent' );

   ok(  defined $subf[0], '$subf[0] defined' );
   ok( !defined $subf[1], '$subf[1] not yet defined' );

   $subf[0]->done;

   ok( defined $subf[1], '$subf[1] defined after $subf[0] done' );

   $subf[1]->done;

   $subf[2]->done;

   ok( $future->is_ready, '$future now ready after subs done' );
   is_deeply( [ $future->get ], [], '$future->get empty for fmap_void' );
}

# fmap_void from CODE
{
   my @subf;
   my $future = fmap_void {
      return $subf[$_[0]] = Future->new
   } generate => do { my $count = 0;
                      sub { return unless $count < 3; $count++ } };

   ok( defined $future, '$future defined for fmap non-concurrent from CODE' );

   ok( defined $subf[0], '$subf[0] defined' );

   $subf[0]->done;
   $subf[1]->done;
   $subf[2]->done;

   ok( $future->is_ready, '$future now ready after subs done from CODE' );
}

# fmap_void concurrent
{
   my @subf;
   my $future = fmap_void {
      return $subf[$_[0]] = Future->new
   } foreach => [ 0 .. 4 ],
     concurrent => 2;

   ok( defined $future, '$future defined for fmap concurrent=2' );

   ok( defined $subf[0], '$subf[0] defined' );
   ok( defined $subf[1], '$subf[1] defined' );

   $subf[0]->done; $subf[1]->done;

   ok( defined $subf[2], '$subf[2] defined' );
   ok( defined $subf[3], '$subf[3] defined' );

   $subf[2]->done; $subf[3]->done;

   ok( defined $subf[4], '$subf[4] deifned' );
   ok( !$future->is_ready, '$future not yet ready while one sub remains' );

   $subf[4]->done;

   ok( $future->is_ready, '$future now ready after concurrent subs done' );
}

# fmap_void on immediates
{
   my $future = fmap_void {
      return Future->new->done
   } foreach => [ 0 .. 2 ];

   ok( $future->is_ready, '$future already ready for fmap on immediates' );
}

# fmap_void fail
{
   my @subf;
   my $future = fmap_void {
      return $subf[$_[0]] = Future->new;
   } foreach => [ 0, 1, 2 ],
     concurrent => 2;

   ok( !$subf[0]->is_cancelled, '$subf[0] not cancelled before failure' );

   $subf[1]->fail( "failure" );

   ok( $subf[0]->is_cancelled, '$subf[0] now cancelled after $subf[1] failure' );
   ok( $future->is_ready, '$future now ready after $sub[1] failure' );
   is( scalar $future->failure, "failure", '$future->failure after $sub[1] failure' );
   ok( !defined $subf[2], '$subf[2] was never started after $subf[1] failure' );
}

# fmap_void immediate fail
{
   my @subf;
   my $future = fmap_void {
      if( $_[0] eq "fail" ) {
         return Future->new->fail( "failure" );
      }
      else {
         $subf[$_[0]] = Future->new;
      }
   } foreach => [ 0, "fail", 2 ],
     concurrent => 3;

   ok( $future->is_ready, '$future is already ready' );
   is( scalar $future->failure, "failure", '$future->failure after immediate failure' );

   ok( $subf[0]->is_cancelled, '$subf[0] is cancelled after immediate failure' );
   ok( !defined $subf[2], '$subf[2] was never started after immediate failure' );
}

# fmap_void cancel
{
   my @subf;
   my $future = fmap_void {
      return $subf[$_[0]] = Future->new;
   } foreach => [ 0, 1, 2 ],
     concurrent => 2;

   $future->cancel;

   ok( $subf[0]->is_cancelled, '$subf[0] now cancelled after ->cancel' );
   ok( $subf[1]->is_cancelled, '$subf[1] now cancelled after ->cancel' );
   ok( !defined $subf[2], '$subf[2] was never started after ->cancel' );
}

# fmap_void return
{
   my $future = fmap_void {
      return Future->new->done;
   } foreach => [ 0 ], return => my $ret = Future->new;

   identical( $future, $ret, 'repeat with return yields correct instance' );
}

done_testing;