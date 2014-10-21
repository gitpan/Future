#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Identity;

use Future;

# cancel
{
   my $future = Future->new;

   my $cancelled;

   identical( $future->on_cancel( sub { $cancelled .= "1" } ), $future, '->on_cancel returns $future' );
   $future->on_cancel( sub { $cancelled .= "2" } );

   my $ready;
   $future->on_ready( sub { $ready++ if shift->is_cancelled } );

   $future->on_done( sub { die "on_done called for cancelled future" } );
   $future->on_fail( sub { die "on_fail called for cancelled future" } );

   $future->on_ready( my $ready_f = Future->new );
   $future->on_done( my $done_f = Future->new );
   $future->on_fail( my $fail_f = Future->new );

   $future->cancel;

   ok( $future->is_ready, '$future->cancel marks future ready' );

   ok( $future->is_cancelled, '$future->cancelled now true' );
   is( $cancelled, "21",      '$future cancel blocks called in reverse order' );

   is( $ready, 1, '$future on_ready still called by cancel' );

   ok( $ready_f->is_cancelled, 'on_ready chained future cnacelled after cancel' );
   ok( !$done_f->is_ready, 'on_done chained future not ready after cancel' );
   ok( !$fail_f->is_ready, 'on_fail chained future not ready after cancel' );

   like( exception { $future->get }, qr/cancelled/, '$future->get throws exception by cancel' );

   ok( !exception { $future->cancel }, '$future->cancel a second time is OK' );
}

# cancel_cb
{
   my $future = Future->new;

   my $cancelled;
   $future->on_cancel( sub { $cancelled++ } );

   my $cancel_cb = $future->cancel_cb;
   is( ref $cancel_cb, "CODE", '->cancel_cb returns CODE reference' );

   $cancel_cb->();
   is( $cancelled, 1, 'Cancellation via ->cancel_cb' );
}

# immediately cancelled
{
   my $future = Future->new;
   $future->cancel;

   my $ready_called;
   $future->on_ready( sub { $ready_called++ } );
   my $done_called;
   $future->on_done( sub { $done_called++ } );
   my $fail_called;
   $future->on_fail( sub { $fail_called++ } );

   $future->on_ready( my $ready_f = Future->new );
   $future->on_done( my $done_f = Future->new );
   $future->on_fail( my $fail_f = Future->new );

   is( $ready_called, 1, 'on_ready invoked for already-cancelled future' );
   ok( !$done_called, 'on_done not invoked for already-cancelled future' );
   ok( !$fail_called, 'on_fail not invoked for already-cancelled future' );

   ok( $ready_f->is_cancelled, 'on_ready chained future cnacelled for already-cancelled future' );
   ok( !$done_f->is_ready, 'on_done chained future not ready for already-cancelled future' );
   ok( !$fail_f->is_ready, 'on_fail chained future not ready for already-cancelled future' );
}

# cancel chaining
{
   my $f1 = Future->new;
   my $f2 = Future->new;

   $f1->on_cancel( $f2 );
   my $cancelled;
   $f2->on_cancel( sub { $cancelled++ } );

   $f1->cancel;
   is( $cancelled, 1, 'Chained cancellation' );
}

# ->done on cancelled
{
   my $f = Future->new;
   $f->cancel;

   ok( eval { $f->done( "ignored" ); 1 }, '->done on cancelled future is ignored' );
   ok( eval { $f->fail( "ignored" ); 1 }, '->fail on cancelled future is ignored' );
}

done_testing;
