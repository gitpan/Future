#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011-2014 -- leonerd@leonerd.org.uk

package Future;

use strict;
use warnings;
no warnings 'recursion'; # Disable the "deep recursion" warning

our $VERSION = '0.23';

use Carp qw(); # don't import croak
use Scalar::Util qw( weaken blessed );
use B qw( svref_2object );

our @CARP_NOT = qw( Future::Utils );

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

It is intended that library functions that perform asynchronous operations
would use future objects to represent outstanding operations, and allow their
calling programs to control or wait for these operations to complete. The
implementation and the user of such an interface would typically make use of
different methods on the class. The methods below are documented in two
sections; those of interest to each side of the interface.

See also L<Future::Utils> which contains useful loop-constructing functions,
to run a future-returning function repeatedly in a loop.

=head2 SUBCLASSING

This class easily supports being subclassed to provide extra behavior, such as
giving the C<get> method the ability to block and wait for completion. This
may be useful to provide C<Future> subclasses with event systems, or similar.

Each method that returns a new future object will use the invocant to
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

In most cases this should allow future-returning modules to be used as if they
were blocking call/return-style modules, by simply appending a C<get> call to
the function or method calls.

 my ( $results, $here ) = future_returning_function( @args )->get;

The F<examples> directory in the distribution contains some examples of how
futures might be integrated with various event systems.

=head2 MODULE DOCUMENTATION

Modules that provide future-returning functions or methods may wish to adopt
the following styles in some way, to document the eventual return values from
these futures.

 func( ARGS, HERE... ) ==> ( RETURN, VALUES... )

 OBJ->method( ARGS, HERE... ) ==> ( RETURN, VALUES... )

Code returning a future that yields no values on success can use empty
parentheses.

 func( ... ) ==> ()

=head2 DEBUGGING

By the time a C<Future> object is destroyed, it ought to have been completed
or cancelled. By enabling debug tracing of objects, this fact can be checked.
If a future object is destroyed without having been completed or cancelled, a
warning message is printed.

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

# Callback flags
use constant {
   CB_DONE   => 1<<0, # Execute callback on done
   CB_FAIL   => 1<<1, # Execute callback on fail
   CB_CANCEL => 1<<2, # Execute callback on cancellation

   CB_SELF   => 1<<3, # Pass $self as first argument
   CB_RESULT => 1<<4, # Pass result/failure as a list

   CB_SEQ_ONDONE => 1<<5, # Sequencing on success (->then)
   CB_SEQ_ONFAIL => 1<<6, # Sequencing on failure (->else)

   CB_SEQ_IMDONE => 1<<7, # $code is in fact immediate ->done result
   CB_SEQ_IMFAIL => 1<<8, # $code is in fact immediate ->fail result
};

use constant CB_ALWAYS => CB_DONE|CB_FAIL|CB_CANCEL;

# Useful for identifying CODE references
sub CvNAME_FILE_LINE
{
   my ( $code ) = @_;
   my $cv = svref_2object( $code );

   my $name = join "::", $cv->STASH->NAME, $cv->GV->NAME;
   return $name unless $cv->GV->NAME eq "__ANON__";

   # $cv->GV->LINE isn't reliable, as outside of perl -d mode all anon CODE
   # in the same file actually shares the same GV. :(
   # Walk the optree looking for the first COP
   my $cop = $cv->START;
   $cop = $cop->next while $cop and ref $cop ne "B::COP";

   sprintf "%s(%s line %d)", $cv->GV->NAME, $cop->file, $cop->line;
}

sub new
{
   my $proto = shift;
   return bless {
      ready     => 0,
      callbacks => [], # [] = [$type, ...]
      ( DEBUG ? ( constructed_at => join " line ", (caller)[1,2] ) : () ),
   }, ( ref $proto || $proto );
}

my $GLOBAL_END;
END { $GLOBAL_END = 1; }

*DESTROY = sub {
   my $self = shift;
   return if $GLOBAL_END;

   return if $self->{ready};

   my $lost_at = join " line ", (caller)[1,2];
   # We can't actually know the real line where the last reference was lost; 
   # a variable set to 'undef' or close of scope, because caller can't see it;
   # the current op has already been updated. The best we can do is indicate
   # 'near'.
   warn "$self was constructed at $self->{constructed_at} and was lost near $lost_at before it was ready.\n";
} if DEBUG;

=head2 $future = Future->wrap( @values )

If given a single argument which is already a C<Future> reference, this will
be returned unmodified. Otherwise, returns a new C<Future> instance that is
already complete, and will yield the given values.

=cut

sub wrap
{
   my $class = shift;
   my @values = @_;

   if( @values == 1 and blessed $values[0] and $values[0]->isa( __PACKAGE__ ) ) {
      return $values[0];
   }
   else {
      return $class->new->done( @values );
   }
}

=head2 $future = Future->call( \&code, @args )

A convenient wrapper for calling a C<CODE> reference that is expected to
return a future. In normal circumstances is equivalent to

 $future = $code->( @args )

except that if the code throws an exception, it is wrapped in a new immediate
fail future. If the return value from the code is not a blessed C<Future>
reference, an immediate fail future is returned instead to complain about this
fact.

=cut

sub call
{
   my $class = shift;
   my ( $code, @args ) = @_;

   my $f;
   eval { $f = $code->( @args ); 1 } or $f = $class->new->fail( $@ );
   blessed $f and $f->isa( "Future" ) or $f = $class->new->fail( "Expected code to return a Future" );

   return $f;
}

sub _mark_ready
{
   my $self = shift;
   $self->{ready} = 1;

   delete $self->{on_cancel};
   my $callbacks = delete $self->{callbacks} or return;

   my $cancelled = $self->{cancelled};
   my $fail      = defined $self->{failure};
   my $done      = !$fail && !$cancelled;

   my @result  = $done ? $self->get :
                 $fail ? $self->failure :
                         ();

   foreach my $cb ( @$callbacks ) {
      my ( $flags, $code ) = @$cb;
      my $is_future = blessed( $code ) && $code->isa( "Future" );

      next if $done      and not( $flags & CB_DONE );
      next if $fail      and not( $flags & CB_FAIL );
      next if $cancelled and not( $flags & CB_CANCEL );

      if( $is_future ) {
         $done ? $code->done( @result ) :
         $fail ? $code->fail( @result ) :
                 $code->cancel;
      }
      elsif( $flags & (CB_SEQ_ONDONE|CB_SEQ_ONFAIL) ) {
         my ( undef, undef, $fseq ) = @$cb;

         my $f2;
         if( $done and $flags & CB_SEQ_ONDONE or
             $fail and $flags & CB_SEQ_ONFAIL ) {

            if( $flags & CB_SEQ_IMDONE ) {
               $fseq->done( @$code );
               next;
            }
            elsif( $flags & CB_SEQ_IMFAIL ) {
               $fseq->fail( @$code );
               next;
            }

            my @args = (
               ( $flags & CB_SELF   ? $self : () ),
               ( $flags & CB_RESULT ? @result : () ),
            );

            unless( eval { $f2 = $code->( @args ); 1 } ) {
               $fseq->fail( $@ );
               next;
            }

            unless( blessed $f2 and $f2->isa( "Future" ) ) {
               die "Expected " . CvNAME_FILE_LINE($code) . " to return a Future\n";
            }

            $fseq->on_cancel( $f2 );
         }
         else {
            $f2 = $self;
         }

         if( $f2->is_ready ) {
            $f2->on_ready( $fseq ) if !$f2->{cancelled};
         }
         else {
            push @{ $f2->{callbacks} }, [ CB_DONE|CB_FAIL, $fseq ];
         }
      }
      else {
         $code->(
            ( $flags & CB_SELF   ? $self : () ),
            ( $flags & CB_RESULT ? @result : () ),
         );
      }
   }
}

sub _state
{
   my $self = shift;
   return !$self->{ready}     ? "pending" :
           $self->{failure}   ? "failed" :
           $self->{cancelled} ? "cancelled" :
                                "done";
}

=head1 IMPLEMENTATION METHODS

These methods would primarily be used by implementations of asynchronous
interfaces.

=cut

=head2 $future->done( @result )

Marks that the leaf future is now ready, and provides a list of values as a
result. (The empty list is allowed, and still indicates the future as ready).
Cannot be called on a dependent future.

Returns the C<$future> to allow easy chaining to create an immediate future by

 return Future->new->done( ... )

If the future is already cancelled, this request is ignored. If the future is
already complete with a result or a failure, an exception is thrown.

=cut

sub done
{
   my $self = shift;

   $self->{cancelled} and return $self;
   $self->{ready} and Carp::croak "$self is already ".$self->_state." and cannot be ->done";
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

Returns the C<$future> to allow easy chaining to create an immediate failed
future by

 return Future->new->fail( ... )

If the future is already cancelled, this request is ignored. If the future is
already complete with a result or a failure, an exception is thrown.

=cut

sub fail
{
   my $self = shift;
   my ( $exception, @details ) = @_;

   $self->{cancelled} and return $self;
   $self->{ready} and Carp::croak "$self is already ".$self->_state." and cannot be ->fail'ed";
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

sub die :method
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
   $self->{ready} and return $self;

   push @{ $self->{on_cancel} }, @_;

   return $self;
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
C<done>, C<fail> or C<cancel> methods invoked when the original future
completes successfully, fails, or is cancelled respectively.

=cut

sub on_ready
{
   my $self = shift;
   my ( $code ) = @_;

   if( $self->{ready} ) {
      my $is_future = blessed( $code ) && $code->isa( "Future" );

      my $fail = defined $self->{failure};
      my $done = !$fail && !$self->{cancelled};

      $is_future ? ( $done ? $code->done( $self->get ) :
                     $fail ? $code->fail( $self->failure ) :
                             $code->cancel )
                 : $code->( $self );
   }
   else {
      push @{ $self->{callbacks} }, [ CB_ALWAYS|CB_SELF, $code ];
   }

   return $self;
}

=head2 $done = $future->is_done

Returns true on a future if it is ready and completed successfully. Returns
false if it is still pending, failed, or was cancelled.

=cut

sub is_done
{
   my $self = shift;
   return $self->{ready} && !$self->{failure} && !$self->{cancelled};
}

=head2 @result = $future->get

=head2 $result = $future->get

If the future is ready and completed successfully, returns the list of
results that had earlier been given to the C<done> method on a leaf future,
or the list of component futures it was waiting for on a dependent future. In
scalar context it returns just the first result value.

If the future is ready but failed, this method raises as an exception the
failure string or object that was given to the C<fail> method.

If the future was cancelled an exception is thrown.

If it is not yet ready and is not of a subclass that provides an C<await>
method an exception is thrown. If it is subclassed to provide an C<await>
method then this is used to wait for the future to be ready, before returning
the result or propagating its failure exception.

=cut

sub await
{
   my $self = shift;
   Carp::croak "$self is not yet complete and does not provide ->await";
}

sub get
{
   my $self = shift;
   $self->await until $self->{ready};
   if( $self->{failure} ) {
      my $exception = $self->{failure}->[0];
      !ref $exception && $exception =~ m/\n$/ ? CORE::die $exception : Carp::croak $exception;
   }
   $self->{cancelled} and Carp::croak "$self was cancelled";
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

   if( $self->{ready} ) {
      return $self if $self->{failure} or $self->{cancelled};

      my $is_future = blessed( $code ) && $code->isa( "Future" );
      $is_future ? $code->done( $self->get ) 
                 : $code->( $self->get );
   }
   else {
      push @{ $self->{callbacks} }, [ CB_DONE|CB_RESULT, $code ];
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
   $self->await until $self->{ready};
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

   if( $self->{ready} ) {
      return $self if not $self->{failure};

      my $is_future = blessed( $code ) && $code->isa( "Future" );
      $is_future ? $code->fail( $self->failure )
                 : $code->( $self->failure );
   }
   else {
      push @{ $self->{callbacks} }, [ CB_FAIL|CB_RESULT, $code ];
   }

   return $self;
}

=head2 $future->cancel

Requests that the future be cancelled, immediately marking it as ready. This
will invoke all of the code blocks registered by C<on_cancel>, in the reverse
order. When called on a dependent future, all its component futures are also
cancelled. It is not an error to attempt to cancel a future that is already
complete or cancelled; it simply has no effect.

Returns the C<$future>.

=cut

sub cancel
{
   my $self = shift;

   return $self if $self->{ready};

   $self->{cancelled}++;
   foreach my $code ( reverse @{ $self->{on_cancel} || [] } ) {
      my $is_future = blessed( $code ) && $code->isa( "Future" );
      $is_future ? $code->cancel
                 : $code->( $self );
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

=head1 SEQUENCING METHODS

The following methods all return a new future to represent the combination of
its invocant followed by another action given by a code reference. The
combined activity waits for the first future to be ready, then may invoke the
code depending on the success or failure of the first, or may run it
regardless. The returned sequence future represents the entire combination of
activity.

In some cases the code should return a future; in some it should return an
immediate result. If a future is returned, the combined future will then wait
for the result of this second one. If the combinined future is cancelled, it
will cancel either the first future or the second, depending whether the first
had completed. If the code block throws an exception instead of returning a
value, the sequence future will fail with that exception as its message and no
further values.

As it is always a mistake to call these sequencing methods in void context and lose the
reference to the returned future (because exception/error handling would be
silently dropped), this method warns in void context.

=cut

sub _sequence
{
   my $f1 = shift;
   my ( $code, $flags ) = @_;

   # For later, we might want to know where we were called from
   my $func = (caller 1)[3];
   $func =~ s/^.*:://;

   if( !defined wantarray ) {
      Carp::carp "Calling ->$func in void context";
   }

   if( $f1->is_ready ) {
      # Take a shortcut
      return $f1 if $f1->is_done and not( $flags & CB_SEQ_ONDONE ) or
                    $f1->failure and not( $flags & CB_SEQ_ONFAIL );

      if( $flags & CB_SEQ_IMDONE ) {
         return Future->new->done( @$code );
      }
      elsif( $flags & CB_SEQ_IMFAIL ) {
         return Future->new->fail( @$code );
      }

      my @args = (
         ( $flags & CB_SELF ? $f1 : () ),
         ( $flags & CB_RESULT ? $f1->is_done ? $f1->get :
                                $f1->failure ? $f1->failure :
                                               () : () ),
      );

      my $fseq;
      unless( eval { $fseq = $code->( @args ); 1 } ) {
         return Future->new->fail( $@ );
      }

      unless( blessed $fseq and $fseq->isa( "Future" ) ) {
         die "Expected " . CvNAME_FILE_LINE($code) . " to return a Future\n";
      }

      return $fseq;
   }

   my $fseq = $f1->new;
   $fseq->on_cancel( $f1 );

   push @{ $f1->{callbacks} }, [ CB_DONE|CB_FAIL|$flags, $code, $fseq ];

   return $fseq;
}

=head2 $future = $f1->then( \&done_code )

Returns a new sequencing C<Future> that runs the code if the first succeeds.
Once C<$f1> succeeds the code reference will be invoked and is passed the list
of results. It should return a future, C<$f2>. Once C<$f2> completes the
sequence future will then be marked as complete with whatever result C<$f2>
gave. If C<$f1> fails then the sequence future will immediately fail with the
same failure and the code will not be invoked.

 $f2 = $done_code->( @result )

=head2 $future = $f1->else( \&fail_code )

Returns a new sequencing C<Future> that runs the code if the first fails. Once
C<$f1> fails the code reference will be invoked and is passed the failure and
details. It should return a future, C<$f2>. Once C<$f2> completes the sequence
future will then be marked as complete with whatever result C<$f2> gave. If
C<$f1> succeeds then the sequence future will immediately succeed with the
same result and the code will not be invoked.

 $f2 = $fail_code->( $exception, @details )

=head2 $future = $f1->then( \&done_code, \&fail_code )

The C<then> method can also be passed the C<$fail_code> block as well, giving
a combination of C<then> and C<else> behaviour.

This operation is designed to be compatible with the semantics of other future
systems, such as Javascript's Q or Promises/A libraries.

=cut

sub then
{
   my $self = shift;
   my ( $done_code, $fail_code ) = @_;

   if( $done_code and !$fail_code ) {
      return $self->_sequence( $done_code, CB_SEQ_ONDONE|CB_RESULT );
   }

   # Complex
   return $self->_sequence( sub {
      my $self = shift;
      if( !$self->{failure} ) {
         return $self unless $done_code;
         return $done_code->( $self->get );
      }
      else {
         return $self unless $fail_code;
         return $fail_code->( $self->failure );
      }
   }, CB_SEQ_ONDONE|CB_SEQ_ONFAIL|CB_SELF );
}

sub else
{
   my $self = shift;
   my ( $fail_code ) = @_;

   return $self->_sequence( $fail_code, CB_SEQ_ONFAIL|CB_RESULT );
}

=head2 $future = $f1->transform( %args )

Returns a new sequencing C<Future> that wraps the one given as C<$f1>. With no
arguments this will be a trivial wrapper; C<$future> will complete or fail
when C<$f1> does, and C<$f1> will be cancelled when C<$future> is.

By passing the following named arguments, the returned C<$future> can be made
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

   return $self->_sequence( sub {
      my $self = shift;
      if( !$self->{failure} ) {
         return $self unless $xfrm_done;
         return $self->new->done( $xfrm_done->( $self->get ) );
      }
      else {
         return $self unless $xfrm_fail;
         return $self->new->fail( $xfrm_fail->( $self->failure ) );
      }
   }, CB_SEQ_ONDONE|CB_SEQ_ONFAIL|CB_SELF );
}

=head2 $future = $f1->then_with_f( \&code )

Returns a new sequencing C<Future> that runs the code if the first succeeds.
Identical to C<then>, except that the code reference will be passed both the
original future, C<$f1>, and its result.

 $f2 = $code->( $f1, @result )

This is useful for conditional execution cases where the code block may just
return the same result of the original future. In this case it is more
efficient to return the original future itself.

=cut

sub then_with_f
{
   my $self = shift;
   my ( $done_code ) = @_;

   return $self->_sequence( $done_code, CB_SEQ_ONDONE|CB_SELF|CB_RESULT );
}

=head2 $future = $f->then_done( @result )

=head2 $future = $f->then_fail( $exception, @details )

Convenient shortcuts to returning an immediate future from a C<then> block,
when the result is already known.

=cut

sub then_done
{
   my $self = shift;
   my ( @result ) = @_;
   return $self->_sequence( \@result, CB_SEQ_ONDONE|CB_SEQ_IMDONE );
}

sub then_fail
{
   my $self = shift;
   my ( @failure ) = @_;
   return $self->_sequence( \@failure, CB_SEQ_ONDONE|CB_SEQ_IMFAIL );
}

=head2 $future = $f1->else_with_f( \&code )

Returns a new sequencing C<Future> that runs the code if the first fails.
Identical to C<else>, except that the code reference will be passed both the
original future, C<$f1>, and its exception and details.

 $f2 = $code->( $f1, $exception, @details )

This is useful for conditional execution cases where the code block may just
return the same result of the original future. In this case it is more
efficient to return the original future itself.

=cut

sub else_with_f
{
   my $self = shift;
   my ( $fail_code ) = @_;

   return $self->_sequence( $fail_code, CB_SEQ_ONFAIL|CB_SELF|CB_RESULT );
}

=head2 $future = $f->else_done( @result )

=head2 $future = $f->else_fail( $exception, @details )

Convenient shortcuts to returning an immediate future from a C<else> block,
when the result is already known.

=cut

sub else_done
{
   my $self = shift;
   my ( @result ) = @_;
   return $self->_sequence( \@result, CB_SEQ_ONFAIL|CB_SEQ_IMDONE );
}

sub else_fail
{
   my $self = shift;
   my ( @failure ) = @_;
   return $self->_sequence( \@failure, CB_SEQ_ONFAIL|CB_SEQ_IMFAIL );
}

=head2 $future = $f1->followed_by( \&code )

Returns a new sequencing C<Future> that runs the code regardless of success or
failure. Once C<$f1> is ready the code reference will be invoked and is passed
one argument, C<$f1>. It should return a future, C<$f2>. Once C<$f2> completes
the sequence future will then be marked as complete with whatever result
C<$f2> gave.

 $f2 = $code->( $f1 )

=cut

sub followed_by
{
   my $self = shift;
   my ( $code ) = @_;

   return $self->_sequence( $code, CB_SEQ_ONDONE|CB_SEQ_ONFAIL|CB_SELF );
}

=head2 $future = $f1->and_then( \&code )

An older form of C<then_with_f>; this method passes only the original future
itself to the code, not its result. The code would have to call C<get> on the
future to obtain the result.

 $f2 = $code->( $f1 )

This method may be removed in a later version; use C<then_with_f> in new code.

=cut

sub and_then
{
   my $self = shift;
   my ( $code ) = @_;

   return $self->_sequence( $code, CB_SEQ_ONDONE|CB_SELF );
}

=head2 $future = $f1->or_else( \&code )

An older form of C<else_with_f>; this method passes only the original future
itself to the code, not its failure and details. The code would have to call
C<failure> on the future to obtain the result.

 $f2 = $code->( $f1 )

This method may be removed in a later version; use C<else_with_f> in new code.

=cut

sub or_else
{
   my $self = shift;
   my ( $code ) = @_;

   return $self->_sequence( $code, CB_SEQ_ONFAIL|CB_SELF );
}

=head1 DEPENDENT FUTURES

The following constructors all take a list of component futures, and return a
new future whose readiness somehow depends on the readiness of those
components. The first derived class component future will be used as the
prototype for constructing the return value, so it respects subclassing
correctly, or failing that a plain C<Future>.

=cut

sub _new_dependent
{
   shift; # ignore this class
   my ( $subs ) = @_;

   foreach my $sub ( @$subs ) {
      blessed $sub and $sub->isa( "Future" ) or Carp::croak "Expected a Future, got $_";
   }

   # Find the best prototype. Ideally anything derived if we can find one.
   my $self;
   ref($_) eq "Future" or $self = $_->new, last for @$subs;

   # No derived ones; just have to be a basic class then
   $self ||= Future->new;

   $self->{subs} = $subs;

   # This might be called by a DESTROY during global destruction so it should
   # be as defensive as possible (see RT88967)
   $self->on_cancel( sub {
      foreach my $sub ( @$subs ) {
         $sub->cancel if $sub and !$sub->{ready};
      }
   } );

   return $self;
}

=head2 $future = Future->wait_all( @subfutures )

Returns a new C<Future> instance that will indicate it is ready once all of
the sub future objects given to it indicate that they are ready, either by
success or failure. Its result will a list of its component futures.

When given an empty list this constructor returns a new immediately-done
future.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub wait_all
{
   my $class = shift;
   my @subs = @_;

   unless( @subs ) {
      my $self = Future->new->done;
      $self->{subs} = [];
      return $self;
   }

   my $self = Future->_new_dependent( \@subs );

   my $pending = 0;
   $_->{ready} or $pending++ for @subs;

   # Look for immediate ready
   if( !$pending ) {
      $self->{result} = [ @subs ];
      $self->_mark_ready;
      return $self;
   }

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->{cancelled};
      return unless $weakself;

      $pending--;
      $pending and return;

      $weakself->{result} = [ @subs ];
      $weakself->_mark_ready;
   };

   foreach my $sub ( @subs ) {
      $sub->{ready} or $sub->on_ready( $sub_on_ready );
   }

   return $self;
}

=head2 $future = Future->wait_any( @subfutures )

Returns a new C<Future> instance that will indicate it is ready once any of
the sub future objects given to it indicate that they are ready, either by
success or failure. Any remaining component futures that are not yet ready
will be cancelled. Its result will be the result of the first component future
that was ready; either success or failure.

When given an empty list this constructor returns an immediately-failed
future.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub wait_any
{
   my $class = shift;
   my @subs = @_;

   unless( @subs ) {
      my $self = Future->new->fail( "Cannot ->wait_any with no subfutures" );
      $self->{subs} = [];
      return $self;
   }

   my $self = Future->_new_dependent( \@subs );

   # Look for immediate ready
   my $immediate_ready;
   foreach my $sub ( @subs ) {
      $sub->{ready} and $immediate_ready = $sub, last;
   }

   if( $immediate_ready ) {
      foreach my $sub ( @subs ) {
         $sub->{ready} or $sub->cancel;
      }

      if( $immediate_ready->{failure} ) {
         $self->{failure} = [ $immediate_ready->failure ];
      }
      else {
         $self->{result} = [ $immediate_ready->get ];
      }
      $self->_mark_ready;
      return $self;
   }

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->{cancelled};
      return unless $weakself;

      foreach my $sub ( @subs ) {
         $sub->{ready} or $sub->cancel;
      }

      if( $_[0]->{failure} ) {
         $weakself->{failure} = [ $_[0]->failure ];
      }
      else {
         $weakself->{result}  = [ $_[0]->get ];
      }
      $weakself->_mark_ready;
   };

   foreach my $sub ( @subs ) {
      # No need to test $sub->{ready} since we know none of them are
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

When given an empty list this constructor returns a new immediately-done
future.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub needs_all
{
   my $class = shift;
   my @subs = @_;

   unless( @subs ) {
      my $self = Future->new->done;
      $self->{subs} = [];
      return $self;
   }

   my $self = Future->_new_dependent( \@subs );

   # Look for immediate fail
   my $immediate_fail;
   foreach my $sub ( @subs ) {
      $sub->{ready} and $sub->{failure} and $immediate_fail = $sub, last;
   }

   if( $immediate_fail ) {
      foreach my $sub ( @subs ) {
         $sub->{ready} or $sub->cancel;
      }

      $self->{failure} = [ $immediate_fail->failure ];
      $self->_mark_ready;
      return $self;
   }

   my $pending = 0;
   $_->{ready} or $pending++ for @subs;

   # Look for immediate done
   if( !$pending ) {
      $self->{result} = [ map { $_->get } @subs ];
      $self->_mark_ready;
      return $self;
   }

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->{cancelled};
      return unless $weakself;

      if( my @failure = $_[0]->failure ) {
         foreach my $sub ( @subs ) {
            $sub->cancel if !$sub->{ready};
         }
         $weakself->{failure} = \@failure;
         $weakself->_mark_ready;
      }
      else {
         $pending--;
         $pending and return;

         $weakself->{result} = [ map { $_->get } @subs ];
         $weakself->_mark_ready;
      }
   };

   foreach my $sub ( @subs ) {
      $sub->{ready} or $sub->on_ready( $sub_on_ready );
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

Normally when this future completes successfully, only one of its component
futures will be done. If it is constructed with multiple that are already done
however, then all of these will be returned from C<done_futures>. Users should
be careful to still check all the results from C<done_futures> in that case.

When given an empty list this constructor returns an immediately-failed
future.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub needs_any
{
   my $class = shift;
   my @subs = @_;

   unless( @subs ) {
      my $self = Future->new->fail( "Cannot ->needs_any with no subfutures" );
      $self->{subs} = [];
      return $self;
   }

   my $self = Future->_new_dependent( \@subs );

   # Look for immediate done
   my $immediate_done;
   my $pending = 0;
   foreach my $sub ( @subs ) {
      $sub->{ready} and !$sub->{failure} and $immediate_done = $sub, last;
      $sub->{ready} or $pending++;
   }

   if( $immediate_done ) {
      foreach my $sub ( @subs ) {
         $sub->{ready} or $sub->cancel;
      }

      $self->{result} = [ $immediate_done->get ];
      $self->_mark_ready;
      return $self;
   }

   # Look for immediate fail
   my $immediate_fail = 1;
   foreach my $sub ( @subs ) {
      $sub->{ready} or $immediate_fail = 0, last;
   }

   if( $immediate_fail ) {
      # For consistency we'll pick the last one for the failure
      $self->{failure} = [ $subs[-1]->{failure} ];
      $self->_mark_ready;
      return $self;
   }

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return if $_[0]->{cancelled};
      return unless $weakself;

      $pending--;

      if( my @failure = $_[0]->failure ) {
         $pending and return;

         $weakself->{failure} = \@failure;
         $weakself->_mark_ready;
      }
      else {
         foreach my $sub ( @subs ) {
            $sub->cancel if !$sub->{ready};
         }
         $weakself->{result} = [ $_[0]->get ];
         $weakself->_mark_ready;
      }
   };

   foreach my $sub ( @subs ) {
      $sub->{ready} or $sub->on_ready( $sub_on_ready );
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
   return grep { not $_->{ready} } @{ $self->{subs} };
}

sub ready_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->ready_futures on a non-dependent Future";
   return grep { $_->{ready} } @{ $self->{subs} };
}

sub done_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->done_futures on a non-dependent Future";
   return grep { $_->{ready} and not $_->{failure} and not $_->{cancelled} } @{ $self->{subs} };
}

sub failed_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->failed_futures on a non-dependent Future";
   return grep { $_->{ready} and $_->{failure} } @{ $self->{subs} };
}

sub cancelled_futures
{
   my $self = shift;
   $self->{subs} or Carp::croak "Cannot call ->cancelled_futures on a non-dependent Future";
   return grep { $_->{ready} and $_->{cancelled} } @{ $self->{subs} };
}

=head1 EXAMPLES

The following examples all demonstrate possible uses of a C<Future>
object to provide a fictional asynchronous API.

For more examples, comparing the use of C<Future> with regular call/return
style Perl code, see also L<Future::Phrasebook>.

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

This is neater handled by the C<wrap> class method, which encapsulates its
arguments in a new immediate C<Future>, except if it is given a single
argument that is already a C<Future>:

 my $f = Future->wrap( $value );

Similarly, the C<fail> and C<die> methods can be used to generate a C<Future>
that is immediately failed.

 my $f = Future->new->die( "This is never going to work" );

This could be considered similarly to a C<die> call.

An C<eval{}> block can be used to turn a C<Future>-returning function that
might throw an exception, into a C<Future> that would indicate this failure.

 my $f = eval { function() } || Future->new->fail( $@ );

This is neater handled by the C<call> class method, which wraps the call in
an C<eval{}> block and tests the result:

 my $f = Future->call( \&function );

=head2 Sequencing

The C<then> method can be used to create simple chains of dependent tasks,
each one executing and returning a C<Future> when the previous operation
succeeds.

 my $f = do_first()
            ->then( sub {
               return do_second();
            })
            ->then( sub {
               return do_third();
            });

The result of the C<$f> future itself will be the result of the future
returned by the final function, if none of them failed. If any of them fails
it will fail with the same failure. This can be considered similar to normal
exception handling in synchronous code; the first time a function call throws
an exception, the subsequent calls are not made.

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

=item *

"Futures advent calendar 2013"

L<http://leonerds-code.blogspot.co.uk/2013/12/futures-advent-day-1.html>

=back

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
