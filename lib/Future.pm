#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011-2013 -- leonerd@leonerd.org.uk

package Future;

use strict;
use warnings;

our $VERSION = '0.09';

use Carp qw(); # don't import croak
use Scalar::Util qw( weaken );

use constant DEBUG => $ENV{PERL_FUTURE_DEBUG};

=head1 NAME

C<Future> - represent an operation awaiting completion

=head1 SYNOPSIS

 my $future = Future->new;

 perform_some_operation(
    on_complete => sub {
       $future->done( @_ );
    }
 );

 $future->on_ready( sub {
    say "The operation is complete";
 } );

=head1 DESCRIPTION

A C<Future> object represents an operation that is currently in progress, or
has recently completed. It can be used in a variety of ways to manage the flow
of control, and data, through an asynchronous program.

Some futures represent a single operation and are explicitly marked as ready
by calling the C<done> or C<fail> methods. These are called "leaf" futures
here, and are returned by the C<new> constructor.

Other futures represent a collection sub-tasks, and are implicitly marked as
ready depending on the readiness of their component futures as required. These
are called "dependent" futures here, and are returned by the various C<wait_*>
and C<need_*> constructors.

It is intended that library functions that perform asynchonous operations
would use C<Future> objects to represent outstanding operations, and allow
their calling programs to control or wait for these operations to complete.
The implementation and the user of such an interface would typically make use
of different methods on the class. The methods below are documented in two
sections; those of interest to each side of the interface.

See also L<Future::Utils> which contains useful loop-constructing functions,
to run a C<Future>-returning function repeatedly in a loop.

=head2 SUBCLASSING

This class easily supports being subclassed to provide extra behavior, such as
giving the C<get> method the ability to block and wait for completion. This
may be useful to provide C<Future> subclasses with event systems, or similar.

Each method that returns a new C<Future> object will use the invocant to
construct its return value. If the constructor needs to perform per-instance
setup it can override the C<new> method, and take context from the given
instance.

 sub new
 {
    my $proto = shift;
    my $self = $proto->SUPER::new;

    if( ref $proto ) {
       # Prototype was an instance
    }
    else {
       # Prototype was a class
    }

    return $self;
 }

If an instance provides a method called C<await>, this will be called by the
C<get> and C<failure> methods if the instance is pending.

 $f->await

The F<examples> directory in the distribution contains some examples of how
C<Future>s might be integrated with various event systems.

=head2 DEBUGGING

By the time a C<Future> object is destroyed, it ought to have been completed
or cancelled. By enabling debug tracing of objects, this fact can be checked.
If a C<Future> object is destroyed without having been completed or cancelled,
a warning message is printed.

This feature is enabled by setting an environment variable called
C<PERL_FUTURE_DEBUG> to some true value.

 $ PERL_FUTURE_DEBUG=1 perl -MFuture -E 'my $f = Future->new'
 Future=HASH(0xaa61f8) was constructed at -e line 1 and was lost near -e line 0 before it was ready.

Note that due to a limitation of perl's C<caller> function within a C<DESTROY>
destructor method, the exact location of the leak cannot be accurately
determined. Often the leak will occur due to falling out of scope by returning
from a function; in this case the leak location may be reported as being the
line following the line calling that function.

 $ PERL_FUTURE_DEBUG=1 perl -MFuture
 sub foo {
    my $f = Future->new;
 }
 
 foo();
 print "Finished\n";
 
 Future=HASH(0x14a2220) was constructed at - line 2 and was lost near - line 6 before it was ready.
 Finished

=cut

=head1 CONSTRUCTORS

=cut

=head2 $future = Future->new

=head2 $future = $orig->new

Returns a new C<Future> instance to represent a leaf future. It will be marked
as ready by any of the C<done>, C<fail>, or C<cancel> methods. It can be
called either as a class method, or as an instance method. Called on an
instance it will construct another in the same class, and is useful for
subclassing.

This constructor would primarily be used by implementations of asynchronous
interfaces.

=cut

sub new
{
   my $proto = shift;
   return bless {
      ready     => 0,
      callbacks => [],
      ( DEBUG ? ( constructed_at => join " line ", (caller)[1,2] ) : () ),
   }, ( ref $proto || $proto );
}

my $GLOBAL_END;
END { $GLOBAL_END = 1; }

*DESTROY = sub {
   my $self = shift;
   return if $GLOBAL_END;

   return if $self->is_ready;

   my $lost_at = join " line ", (caller)[1,2];
   # We can't actually know the real line where the last reference was lost; 
   # a variable set to 'undef' or close of scope, because caller can't see it;
   # the current op has already been updated. The best we can do is indicate
   # 'near'.
   warn "$self was constructed at $self->{constructed_at} and was lost near $lost_at before it was ready.\n";
} if DEBUG;

=head2 $future = $f1->followed_by( \&code )

Returns a new C<Future> instance that allows a sequence of operations to be
performed. Once C<$f1> is ready, the code reference will be invoked and is
passed one argument, being C<$f1>. It should return a future, C<$f2>. Once
C<$f2> indicates completion the combined future C<$future> will then be marked
as complete, with whatever result C<$f2> gave.

 $f2 = $code->( $f1 )

If C<$future> is cancelled before C<$f1> completes, then C<$f1> will be
cancelled. If it is cancelled after completion then C<$f2> is cancelled
instead.

=cut

sub followed_by
{
   my $f1 = shift;
   my ( $code ) = @_;

   my $fseq = $f1->new;

   my $f2;

   $f1->on_ready( sub {
      my $self = shift;

      return if $self->is_cancelled;

      $f2 = $code->( $self );

      $f2->on_ready( sub {
         my $f2 = shift;
         if( $f2->is_cancelled ) {
            return;
         }
         elsif( $f2->failure ) {
            $fseq->fail( $f2->failure );
         }
         else {
            $fseq->done( $f2->get );
         }
      } );
   } );

   $fseq->on_cancel( sub {
      ( $f2 || $f1 )->cancel
   } ) if not $fseq->is_ready;

   return $fseq;
}

=head2 $future = $f1->and_then( \&code )

A convenient shortcut to C<followed_by>, which invokes the supplied code
reference only if the first future completes successfully. If it fails, then
the returned future will fail with the same error and the code reference will
not be invoked.

=cut

sub and_then
{
   my $self = shift;
   my ( $code ) = @_;

   return $self->followed_by( sub {
      my $self = shift;
      return $self if $self->failure;
      return $code->( $self );
   });
}

=head2 $future = $f1->or_else( \&code )

A convenient shortcut to C<followed_by>, which invokes the supplied code
reference only if the first future fails. If it completes successfully, then
the returned future will complete with the same result and the code reference
will not be invoked.

=cut

sub or_else
{
   my $self = shift;
   my ( $code ) = @_;

   return $self->followed_by( sub {
      my $self = shift;
      return $self if not $self->failure;
      return $code->( $self );
   });
}

=head2 $future = $f1->transform( %args )

Returns a new C<Future> instance that wraps the one given as C<$f1>. With no
arguments this will be a trivial wrapper; C<$future> will complete or fail
when C<$f1> does, and C<$f1> will be cancelled when C<$future> is.

By passing the following named argmuents, the returned C<$future> can be made
to behave differently to C<$f1>:

=over 8

=item done => CODE

Provides a function to use to modify the result of a successful completion.
When C<$f1> completes successfully, the result of its C<get> method is passed
into this function, and whatever it returns is passed to the C<done> method of
C<$future>

=item fail => CODE

Provides a function to use to modify the result of a failure. When C<$f1>
fails, the result of its C<failure> method is passed into this function, and
whatever it returns is passed to the C<fail> method of C<$future>.

=back

=cut

sub transform
{
   my $self = shift;
   my %args = @_;

   my $xfrm_done = $args{done};
   my $xfrm_fail = $args{fail};

   return $self->followed_by( sub {
      my $self = shift;
      if( !$self->failure ) {
         return $self->new->done( $xfrm_done ? $xfrm_done->( $self->get ) : $self->get );
      }
      else {
         return $self->new->fail( $xfrm_fail ? $xfrm_fail->( $self->failure ) : $self->failure );
      }
   });
}

sub _mark_ready
{
   my $self = shift;
   $self->{ready} = 1;

   my $failed = defined $self->failure;
   my $done   = !$failed && !$self->is_cancelled;

   foreach my $cb ( @{ $self->{callbacks} } ) {
      my ( $type, $code ) = @$cb;
      my $is_future = eval { $code->isa( "Future" ) };

      if( $type eq "ready" ) {
         $is_future ? ( $done ? $code->done( $self->get )
                              : $code->fail( $self->failure ) )
                    : $code->( $self );
      }
      elsif( $type eq "done" and $done ) {
         $is_future ? $code->done( $self->get ) 
                    : $code->( $self->get );
      }
      elsif( $type eq "failed" and $failed ) {
         $is_future ? $code->fail( $self->failure )
                    : $code->( $self->failure );
      }
   }

   delete $self->{callbacks}; # To drop references
}

=head1 IMPLEMENTATION METHODS

These methods would primarily be used by implementations of asynchronous
interfaces.

=cut

=head2 $future->done( @result )

Marks that the leaf future is now ready, and provides a list of values as a
result. (The empty list is allowed, and still indicates the future as ready).
Cannot be called on a dependent future.

Returns the C<$future>.

=cut

sub done
{
   my $self = shift;

   $self->is_ready and Carp::croak "$self is already complete and cannot be ->done twice";
   $self->{subs} and Carp::croak "$self is not a leaf Future, cannot be ->done";
   $self->{result} = [ @_ ];
   $self->_mark_ready;

   return $self;
}

=head2 $code = $future->done_cb

Returns a C<CODE> reference that, when invoked, calls the C<done> method. This
makes it simple to pass as a callback function to other code.

The same effect can be achieved using L<curry>:

 $code = $future->curry::done;

=cut

sub done_cb
{
   my $self = shift;
   return sub { $self->done( @_ ) };
}

=head2 $future->fail( $exception, @details )

Marks that the leaf future has failed, and provides an exception value. This
exception will be thrown by the C<get> method if called. 

The exception must evaluate as a true value; false exceptions are not allowed.
Further details may be provided that will be returned by the C<failure> method
in list context. These details will not be part of the exception string raised
by C<get>.

Returns the C<$future>.

=cut

sub fail
{
   my $self = shift;
   my ( $exception, @details ) = @_;

   $self->is_ready and Carp::croak "$self is already complete and cannot be ->fail'ed";
   $self->{subs} and Carp::croak "$self is not a leaf Future, cannot be ->fail'ed";
   $_[0] or Carp::croak "$self ->fail requires an exception that is true";
   $self->{failure} = [ $exception, @details ];
   $self->_mark_ready;

   return $self;
}

=head2 $code = $future->fail_cb

Returns a C<CODE> reference that, when invoked, calls the C<fail> method. This
makes it simple to pass as a callback function to other code.

The same effect can be achieved using L<curry>:

 $code = $future->curry::fail;

=cut

sub fail_cb
{
   my $self = shift;
   return sub { $self->fail( @_ ) };
}

=head2 $future->die( $message, @details )

A convenient wrapper around C<fail>. If the exception is a non-reference that
does not end in a linefeed, its value will be extended by the file and line
number of the caller, similar to the logic that C<die> uses.

Returns the C<$future>.

=cut

sub die
{
   my $self = shift;
   my ( $exception, @details ) = @_;

   if( !ref $exception and $exception !~ m/\n$/ ) {
      $exception .= sprintf " at %s line %d\n", (caller)[1,2];
   }

   $self->fail( $exception, @details );
}

=head2 $future->on_cancel( $code )

If the future is not yet ready, adds a callback to be invoked if the future is
cancelled by the C<cancel> method. If the future is already ready, throws an
exception.

If the future is cancelled, the callbacks will be invoked in the reverse order
to that in which they were registered.

 $on_cancel->( $future )

=head2 $future->on_cancel( $f )

If passed another C<Future> instance, the passed instance will be cancelled
when the original future is cancelled. This method does nothing if the future
is already complete.

=cut

sub on_cancel
{
   my $self = shift;
   $self->is_ready and return;
   push @{ $self->{on_cancel} }, @_;
}

=head2 $cancelled = $future->is_cancelled

Returns true if the future has been cancelled by C<cancel>.

=cut

sub is_cancelled
{
   my $self = shift;
   return $self->{cancelled};
}

=head1 USER METHODS

These methods would primarily be used by users of asynchronous interfaces, on
objects returned by such an interface.

=cut

=head2 $ready = $future->is_ready

Returns true on a leaf future if a result has been provided to the C<done>
method, failed using the C<fail> method, or cancelled using the C<cancel>
method.

Returns true on a dependent future if it is ready to yield a result, depending
on its component futures.

=cut

sub is_ready
{
   my $self = shift;
   return $self->{ready};
}

=head2 $future->on_ready( $code )

If the future is not yet ready, adds a callback to be invoked when the future
is ready. If the future is already ready, invokes it immediately.

In either case, the callback will be passed the future object itself. The
invoked code can then obtain the list of results by calling the C<get> method.

 $on_ready->( $future )

Returns the C<$future>.

=head2 $future->on_ready( $f )

If passed another C<Future> instance, the passed instance will have its
C<done> or C<fail> methods invoked when the original future completes
successfully or fails respectively.

=cut

sub on_ready
{
   my $self = shift;
   my ( $code ) = @_;

   if( $self->is_ready ) {
      my $is_future = eval { $code->isa( "Future" ) };
      my $done = !$self->failure && !$self->is_cancelled;

      $is_future ? ( $done ? $code->done( $self->get )
                           : $code->fail( $self->failure ) )
                 : $code->( $self );
   }
   else {
      push @{ $self->{callbacks} }, [ ready => $code ];
   }

   return $self;
}

=head2 @result = $future->get

=head2 $result = $future->get

If the future is ready and completed successfully, returns the list of
results that had earlier been given to the C<done> method on a leaf future,
or the list of component futures it was waiting for on a dependent future. In
scalar context it returns just the first result value.

If the future is ready but failed, this method raises as an exception the
failure string or object that was given to the C<fail> method.

If it is not yet ready, or was cancelled, an exception is thrown.

=cut

sub await
{
   my $self = shift;
   Carp::croak "$self is not yet complete";
}

sub get
{
   my $self = shift;
   $self->await until $self->is_ready;
   if( $self->{failure} ) {
      my $exception = $self->{failure}->[0];
      !ref $exception && $exception =~ m/\n$/ ? CORE::die $exception : Carp::croak $exception;
   }
   $self->is_cancelled and Carp::croak "$self was cancelled";
   return $self->{result}->[0] unless wantarray;
   return @{ $self->{result} };
}

=head2 $future->on_done( $code )

If the future is not yet ready, adds a callback to be invoked when the future
is ready, if it completes successfully. If the future completed successfully,
invokes it immediately. If it failed or was cancelled, it is not invoked at
all.

The callback will be passed the result passed to the C<done> method.

 $on_done->( @result )

Returns the C<$future>.

=head2 $future->on_done( $f )

If passed another C<Future> instance, the passed instance will have its
C<done> method invoked when the original future completes successfully.

=cut

sub on_done
{
   my $self = shift;
   my ( $code ) = @_;

   if( $self->is_ready ) {
      return if $self->failure or $self->is_cancelled;

      my $is_future = eval { $code->isa( "Future" ) };
      $is_future ? $code->done( $self->get ) 
                 : $code->( $self->get );
   }
   else {
      push @{ $self->{callbacks} }, [ done => $code ];
   }

   return $self;
}

=head2 $exception = $future->failure

=head2 $exception, @details = $future->failure

Returns the exception passed to the C<fail> method, C<undef> if the future
completed successfully via the C<done> method, or raises an exception if
called on a future that is not yet ready.

If called in list context, will additionally yield a list of the details
provided to the C<fail> method.

Because the exception value must be true, this can be used in a simple C<if>
statement:

 if( my $exception = $future->failure ) {
    ...
 }
 else {
    my @result = $future->get;
    ...
 }

=cut

sub failure
{
   my $self = shift;
   $self->await until $self->is_ready;
   return unless $self->{failure};
   return $self->{failure}->[0] if !wantarray;
   return @{ $self->{failure} };
}

=head2 $future->on_fail( $code )

If the future is not yet ready, adds a callback to be invoked when the future
is ready, if it fails. If the future has already failed, invokes it
immediately. If it completed successfully or was cancelled, it is not invoked
at all.

The callback will be passed the exception and details passed to the C<fail>
method.

 $on_fail->( $exception, @details )

Returns the C<$future>.

=head2 $future->on_fail( $f )

If passed another C<Future> instance, the passed instance will have its
C<fail> method invoked when the original future fails.

To invoke a C<done> method on a future when another one fails, use a CODE
reference:

 $future->on_fail( sub { $f->done( @_ ) } );

=cut

sub on_fail
{
   my $self = shift;
   my ( $code ) = @_;

   if( $self->is_ready ) {
      return if not $self->failure;

      my $is_future = eval { $code->isa( "Future" ) };
      $is_future ? $code->fail( $self->failure )
                 : $code->( $self->failure );
   }
   else {
      push @{ $self->{callbacks} }, [ failed => $code ];
   }

   return $self;
}

=head2 $future->cancel

Requests that the future be cancelled, immediately marking it as ready. This
will invoke all of the code blocks registered by C<on_cancel>, in the reverse
order. When called on a dependent future, all its component futures are also
cancelled. It is not an error to attempt to cancel a Future that is already
complete or cancelled; it simply has no effect.

Returns the C<$future>.

=cut

sub cancel
{
   my $self = shift;

   return if $self->is_ready;

   $self->{cancelled}++;
   foreach my $cb ( reverse @{ $self->{on_cancel} || [] } ) {
      my $is_future = eval { $cb->isa( "Future" ) };
      $is_future ? $cb->cancel
                 : $cb->( $self );
   }
   $self->_mark_ready;

   return $self;
}

=head2 $code = $future->cancel_cb

Returns a C<CODE> reference that, when invoked, calls the C<cancel> method.
This makes it simple to pass as a callback function to other code.

The same effect can be achieved using L<curry>:

 $code = $future->curry::cancel;

=cut

sub cancel_cb
{
   my $self = shift;
   return sub { $self->cancel };
}

=head1 DEPENDENT FUTURES

The following constructors all take a list of component futures, and return a
new future whose readiness somehow depends on the readiness of those
components. The first component future will be used as the prototype for
constructing the return value, so it respects subclassing correctly.

=cut

sub _new_dependent
{
   shift; # ignore this class
   my ( $subs ) = @_;
   my $self = $subs->[0]->new;

   eval { $_->isa( "Future" ) } or Carp::croak "Expected a Future, got $_" for @$subs;

   $self->{subs} = $subs;

   $self->on_cancel( sub {
      foreach my $sub ( @$subs ) {
         $sub->cancel if !$sub->is_ready;
      }
   } );

   return $self;
}

=head2 $future = Future->wait_all( @subfutures )

Returns a new C<Future> instance that will indicate it is ready once all of
the sub future objects given to it indicate that they are ready. Its result
will a list of its component futures.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub wait_all
{
   my $class = shift;
   my @subs = @_;

   my $self = Future->_new_dependent( \@subs );

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->is_cancelled;
      return unless $weakself;

      foreach my $sub ( @subs ) {
         $sub->is_ready or return;
      }

      $weakself->{result} = [ @subs ];
      $weakself->_mark_ready;
   };

   foreach my $sub ( @subs ) {
      $sub->on_ready( $sub_on_ready );
   }

   return $self;
}

=head2 $future = Future->wait_any( @subfutures )

Returns a new C<Future> instance that will indicate it is ready once any of
the sub future objects given to it indicate that they are ready. Any remaining
component futures that are not yet ready will be cancelled. Its result will be
the result of the first component future that was ready; either success or
failure.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub wait_any
{
   my $class = shift;
   my @subs = @_;

   my $self = Future->_new_dependent( \@subs );

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->is_cancelled;
      return unless $weakself;

      foreach my $sub ( @subs ) {
         $sub->is_ready or $sub->cancel;
      }

      if( $_[0]->failure ) {
         $weakself->{failure} = [ $_[0]->failure ];
      }
      else {
         $weakself->{result}  = [ $_[0]->get ];
      }
      $weakself->_mark_ready;
   };

   foreach my $sub ( @subs ) {
      $sub->on_ready( $sub_on_ready );
   }

   return $self;
}

=head2 $future = Future->needs_all( @subfutures )

Returns a new C<Future> instance that will indicate it is ready once all of the
sub future objects given to it indicate that they have completed successfully,
or when any of them indicates that they have failed. If any sub future fails,
then this will fail immediately, and the remaining subs not yet ready will be
cancelled.

If successful, its result will be a concatenated list of the results of all
its component futures, in corresponding order. If it fails, its failure will
be that of the first component future that failed. To access each component
future's results individually, use C<done_futures>.

(B<NOTE>: this result is different from versions of C<Future> before 0.03.)

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub needs_all
{
   my $class = shift;
   my @subs = @_;

   my $self = Future->_new_dependent( \@subs );

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->is_cancelled;
      return unless $weakself;

      if( my @failure = $_[0]->failure ) {
         foreach my $sub ( @subs ) {
            $sub->cancel if !$sub->is_ready;
         }
         $weakself->{failure} = \@failure;
         $weakself->_mark_ready;
      }
      else {
         foreach my $sub ( @subs ) {
            $sub->is_ready or return;
         }
         $weakself->{result} = [ map { $_->get } @subs ];
         $weakself->_mark_ready;
      }
   };

   foreach my $sub ( @subs ) {
      $sub->on_ready( $sub_on_ready );
   }

   return $self;
}

=head2 $future = Future->needs_any( @subfutures )

Returns a new C<Future> instance that will indicate it is ready once any of
the sub future objects given to it indicate that they have completed
successfully, or when all of them indicate that they have failed. If any sub
future succeeds, then this will succeed immediately, and the remaining subs
not yet ready will be cancelled.

If successful, its result will be that of the first component future that
succeeded. If it fails, its failure will be that of the last component future
to fail. To access the other failures, use C<failed_futures>.

(B<NOTE>: this result is different from versions of C<Future> before 0.03.)

Normally when this Future completes successfully, only one of its component
futures will be done. If it is constructed with multiple that are already done
however, then all of these will be returned from C<done_futures>. Users should
be careful to still check all the results from C<done_futures> in that case.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub needs_any
{
   my $class = shift;
   my @subs = @_;

   my $self = Future->_new_dependent( \@subs );

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->is_cancelled;
      return unless $weakself;

      if( my @failure = $_[0]->failure ) {
         foreach my $sub ( @subs ) {
            $sub->is_ready or return;
         }
         $weakself->{failure} = \@failure;
         $weakself->_mark_ready;
      }
      else {
         foreach my $sub ( @subs ) {
            $sub->cancel if !$sub->is_ready;
         }
         $weakself->{result} = [ $_[0]->get ];
         $weakself->_mark_ready;
      }
   };

   foreach my $sub ( @subs ) {
      $sub->on_ready( $sub_on_ready );
   }

   return $self;
}

=head1 METHODS ON DEPENDENT FUTURES

The following methods apply to dependent (i.e. non-leaf) futures, to access
the component futures stored by it.

=cut

=head2 @f = $future->pending_futures

=head2 @f = $future->ready_futures

=head2 @f = $future->done_futures

=head2 @f = $future->failed_futures

=head2 @f = $future->cancelled_futures

Return a list of all the pending, ready, done, failed, or cancelled
component futures. In scalar context, each will yield the number of such
component futures.

=cut

sub pending_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->pending_futures on a non-dependent Future";
   return grep { not $_->is_ready } @{ $self->{subs} };
}

sub ready_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->ready_futures on a non-dependent Future";
   return grep { $_->is_ready } @{ $self->{subs} };
}

sub done_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->done_futures on a non-dependent Future";
   return grep { $_->is_ready and not $_->failure and not $_->is_cancelled } @{ $self->{subs} };
}

sub failed_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->failed_futures on a non-dependent Future";
   return grep { $_->is_ready and $_->failure } @{ $self->{subs} };
}

sub cancelled_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->cancelled_futures on a non-dependent Future";
   return grep { $_->is_ready and $_->is_cancelled } @{ $self->{subs} };
}

=head1 EXAMPLES

The following examples all demonstrate possible uses of a C<Future>
object to provide a fictional asynchronous API function called simply
C<koperation>.

=head2 Providing Results

By returning a new C<Future> object each time the asynchronous function is
called, it provides a placeholder for its eventual result, and a way to
indicate when it is complete.

 sub foperation
 {
    my %args = @_;

    my $future = Future->new;

    do_something_async(
       foo => $args{foo},
       on_done => sub { $future->done( @_ ); },
    );

    return $future;
 }

In most cases, the C<done> method will simply be invoked with the entire
result list as its arguments. In that case, it is simpler to use the
C<done_cb> wrapper method to create the C<CODE> reference.

    my $future = Future->new;

    do_something_async(
       foo => $args{foo},
       on_done => $future->done_cb,
    );

The caller may then use this future to wait for a result using the C<on_ready>
method, and obtain the result using C<get>.

 my $f = foperation( foo => "something" );

 $f->on_ready( sub {
    my $f = shift;
    say "The operation returned: ", $f->get;
 } );

=head2 Indicating Success or Failure

Because the stored exception value of a failed future may not be false, the
C<failure> method can be used in a conditional statement to detect success or
failure.

 my $f = foperation( foo => "something" );

 $f->on_ready( sub {
    my $f = shift;
    if( not my $e = $f->failure ) {
       say "The operation succeeded with: ", $f->get;
    }
    else {
       say "The operation failed with: ", $e;
    }
 } );

By using C<not> in the condition, the order of the C<if> blocks can be
arranged to put the successful case first, similar to a C<try>/C<catch> block.

Because the C<get> method re-raises the passed exception if the future failed,
it can be used to control a C<try>/C<catch> block directly. (This is sometimes
called I<Exception Hoisting>).

 use Try::Tiny;

 $f->on_ready( sub {
    my $f = shift;
    try {
       say "The operation succeeded with: ", $f->get;
    }
    catch {
       say "The operation failed with: ", $_;
    };
 } );

Even neater still may be the separate use of the C<on_done> and C<on_fail>
methods.

 $f->on_done( sub {
    my @result = @_;
    say "The operation succeeded with: ", @result;
 } );
 $f->on_fail( sub {
    my ( $failure ) = @_;
    say "The operation failed with: $failure";
 } );

=head2 Immediate Futures

Because the C<done> method returns the future object itself, it can be used to
generate a C<Future> that is immediately ready with a result.

 my $f = Future->new->done( $value );

Similarly, the C<fail> and C<die> methods can be used to generate a C<Future>
that is immediately failed.

 my $f = Future->new->die( "This is never going to work" );

This could be considered similarly to a C<die> call.

=head2 Sequencing

The C<and_then> method can be used to create simple chains of dependent tasks,
each one executing and returning a C<Future> when the previous operation
succeeds.

 my $f = do_first()
            ->and_then( sub {
               return do_second();
            })
            ->and_then( sub {
               return do_third();
            });

The result of the C<$f> future itself will be the result of the future
returned by the final function, if none of them failed. If any of them fails
it will fail with the same failure. This can be considered similar to normal
exception handling in synchronous code; the first time a function call throws
an exception, the subsequent calls are not made.

=head2 Catching Errors

The C<or_else> method can be used to create error handling logic, similar to
the kind that can be performed synchronously with C<eval> or L<Try::Tiny>.

 my $f = try_this()
            ->or_else( sub {
               return handle_failure();
            });

The result of the returned future will be what the first function's future
returned, if it was successful, or else whatever the second function's future
returned.

As the failure-handling code block is given the failed future, and has to
return a future; it can return the failed future itself to apply some clean-up
logic similar to catching but re-throwing an exception:

 my $f = try_this()
            ->or_else( sub {
               my $failure = shift;
               cleanup();
               return $failure;
            });

The C<followed_by> method can attach a code block that is run whenever a
future is ready, regardless of whether it succeeded or failed. This can be
used to create an additional C<finally>-like block. If the C<followed_by>
block returns the future it was passed, then the entire combination still
succeeds or fails according to the result of the first.

 my $f = try_this()
            ->followed_by( sub {
               finally_this()
               return $_[0];
            });

A combination of C<or_else> and C<followed_by> can create a structure similar
to the full C<try>/C<catch>/C<finally> semantics.

 my $f = try_this()
            ->or_else( sub {
               return catch_this();
            })
            ->followed_by( sub {
               finally_this();
               return $_[0];
            });

=head2 Merging Control Flow

A C<wait_all> future may be used to resynchronise control flow, while waiting
for multiple concurrent operations to finish.

 my $f1 = foperation( foo => "something" );
 my $f2 = foperation( bar => "something else" );

 my $f = Future->wait_all( $f1, $f2 );

 $f->on_ready( sub {
    say "Operations are ready:";
    say "  foo: ", $f1->get;
    say "  bar: ", $f2->get;
 } );

This provides an ability somewhat similar to C<CPS::kpar()> or
L<Async::MergePoint>.

=cut

=head1 SEE ALSO

=over 4

=item *

L<curry> - Create automatic curried method call closures for any class or
object

=item *

"The Past, The Present and The Future" - slides from a talk given at the
London Perl Workshop, 2012.

L<https://docs.google.com/presentation/d/1UkV5oLcTOOXBXPh8foyxko4PR28_zU_aVx6gBms7uoo/edit>

=back

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
