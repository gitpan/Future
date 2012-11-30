package Future::AnyEvent;
use base qw( Future );
use AnyEvent;

sub await
{
   my $self = shift;
   my $cv = AnyEvent->condvar;
   $self->on_ready( sub { $cv->send } );
   $cv->recv;
}

sub new_delay
{
   my $self = shift->new;
   $self->{w} = AnyEvent->timer( after => shift, cb => $self->done_cb );
   return $self;
}

package main;

my $timer = Future::AnyEvent->new_delay( 3 );
print "Awaiting 3 seconds...\n";

$timer->get;
print "Done\n";
