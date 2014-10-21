#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

use Future;
use Future::Utils qw( repeat try_repeat try_repeat_until_success );

{
   my $trial_f;
   my $previous_trial;
   my $arg;
   my $again;
   my $future = repeat {
      $previous_trial = shift;
      return $trial_f = Future->new
   } while => sub { $arg = shift; $again };

   ok( defined $future, '$future defined for repeat while' );

   ok( defined $trial_f, 'An initial future is running' );

   my $first_f = $trial_f;

   $again = 1;
   $trial_f->done( "one" );

   ok( defined $arg, '$arg defined for while test' );
   is( scalar $arg->get, "one", '$arg->get for first' );

   identical( $previous_trial, $first_f, 'code block is passed previous trial' );

   $again = 0;
   $trial_f->done( "two" );

   ok( $future->is_ready, '$future is now ready after second attempt ->done' );
   is( scalar $future->get, "two", '$future->get' );
}

# return keyword
{
   my $trial_f;
   my $future = repeat {
      return $trial_f = Future->new
   } while => sub { 1 }, return => my $ret = Future->new;

   identical( $future, $ret, 'repeat with return yields correct instance' );
}

# cancellation
{
   my @running; my $i = 0;
   my $future = repeat {
      return $running[$i++] = Future->new
   } while => sub { 1 };

   ok( defined $future, '$future defined for repeat while' );

   ok( defined $running[0], 'An initial future is running' );

   $running[0]->done;

   $future->cancel;

   ok( !$running[0]->is_cancelled, 'previously running future not cancelled' );
   ok(  $running[1]->is_cancelled, 'running future cancelled after eventual is cancelled' );
   ok( !$running[2],               'a third trial is not started' );
}

# until
{
   my $trial_f;
   my $arg;
   my $accept;
   my $future = repeat {
      return $trial_f = Future->new
   } until => sub { $arg = shift; $accept };

   ok( defined $future, '$future defined for repeat until' );

   ok( defined $trial_f, 'An initial future is running' );

   $accept = 0;
   $trial_f->done( "three" );

   ok( defined $arg, '$arg defined for while test' );
   is( scalar $arg->get, "three", '$arg->get for first' );

   $accept = 1;
   $trial_f->done( "four" );

   ok( $future->is_ready, '$future is now ready after second attempt ->done' );
   is( scalar $future->get, "four", '$future->get' );
}

# code dies
{
   my $future;

   $future = repeat {
      die "It failed\n";
   } while => sub { !shift->failure };

   is( $future->failure, "It failed\n", 'repeat while failure after code exception' );

   $future = repeat {
      die "It failed\n";
   } until => sub { shift->failure };

   is( $future->failure, "It failed\n", 'repeat until failure after code exception' );
}

# Non-Future return fails
{
   my $future;

   $future = repeat {
      "non-Future"
   } while => sub { !shift->failure };

   is( $future->failure, "Expected code to return a Future", 'repeat failure for non-Future return' );
}

# try_repeat catches failures
{
   my $attempt = 0;
   my $future = try_repeat {
      if( ++$attempt < 3 ) {
         return FUture->new->fail( "Too low" );
      }
      else {
         return Future->new->done( $attempt );
      }
   } while => sub { shift->failure };

   ok( $future->is_ready, '$future is now ready for try_repeat' );
   is( scalar $future->get, 3, '$future->get' );
}

{
   my $attempt = 0;
   my $future = try_repeat_until_success {
      if( ++$attempt < 3 ) {
         return Future->new->fail( "Too low" );
      }
      else {
         return Future->new->done( $attempt );
      }
   };

   ok( $future->is_ready, '$future is now ready for try_repeat_until_success' );
   is( scalar $future->get, 3, '$future->get' );
}

# repeat prints a warning if asked to retry a failure
{
   my $warnings = "";
   local $SIG{__WARN__} = sub { $warnings .= join "", @_ };

   my $attempt = 0;
   my $future = repeat {
      if( ++$attempt < 3 ) {
         return Future->new->fail( "try again" );
      }
      else {
         return Future->new->done( "OK" );
      }
   } while => sub { $_[0]->failure };

   ok( $future->is_ready, '$future is now ready after repeat retries failures' );
   like( $warnings, qr/^Using Future::Utils::repeat to retry a failure is deprecated; use try_repeat instead at \Q$0\E line \d+\.$/,
      'Warnings printing by repeat retries failures' );
}

done_testing;
