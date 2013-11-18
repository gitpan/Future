#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Future::Utils;

use strict;
use warnings;

our $VERSION = '0.20';

use Exporter 'import';

our @EXPORT_OK = qw(
   repeat
   try_repeat try_repeat_until_success
   repeat_until_success

   fmap fmap_concat
   fmap1
   fmap_void
);

use Carp;
our @CARP_NOT = qw( Future );

=head1 NAME

C<Future::Utils> - utility functions for working with C<Future> objects

=head1 SYNOPSIS

 use Future::Utils qw( repeat try_repeat try_repeat_until_success );

 my $eventual_f = repeat {
    my $trial_f = ...
    return $trial_f;
 } while => sub { my $f = shift; return want_more($f) };

 my $eventual_f = repeat {
    ...
    return $trail_f;
 } until => sub { my $f = shift; return acceptable($f) };

 my $eventual_f = repeat {
    my $item = shift;
    ...
    return $trial_f;
 } foreach => \@items;

 my $eventual_f = try_repeat {
    my $trial_f = ...
    return $trial_f;
 } while => sub { ... };

 my $eventual_f = try_repeat_until_success {
    ...
    return $trial_f;
 };

 my $eventual_f = try_repeat_until_success {
    my $item = shift;
    ...
    return $trial_f;
 } foreach => \@items;

Z<>
 use Future::Utils qw( fmap fmap1 fmap_void );

 my $result_f = fmap {
    my $item = shift;
    ...
    return $item_f;
 } foreach => \@items, concurrent => 4;

 my $result_f = fmap1 {
    my $item = shift;
    ...
    return $item_f;
 } foreach => \@items, concurrent => 8;

 my $done_f = fmap_void {
    my $item = shift;
    ...
    return $item_f;
 } foreach => \@items, concurrent => 10;

=cut

=head1 REPEATING A BLOCK OF CODE

The C<repeat> function provides a way to repeatedly call a block of code that
returns a L<Future> (called here a "trial future") until some ending condition
is satisfied. The C<repeat> function itself returns a C<Future> to represent
running the repeating loop until that end condition (called here the "eventual
future"). The first time the code block is called, it is passed no arguments,
and each subsequent invocation is passed the previous trial future.

The result of the eventual future is the result of the last trial future.

If the eventual future is cancelled, the latest trial future will be
cancelled.

If some specific subclass or instance of C<Future> is required as the return
value, it can be passed as the C<return> argument. Otherwise the return value
will be constructed by cloning the first non-immediate trial C<Future>.

=head2 $future = repeat { CODE } while => CODE

Repeatedly calls the C<CODE> block while the C<while> condition returns a true
value. Each time the trial future completes, the C<while> condition is passed
the trial future.

 $trial_f = $code->( $previous_trial_f )
 $again = $while->( $trial_f )

If the C<$code> block dies entirely and throws an exception, this will be
caught and considered as an immediately-failed C<Future> with the exception as
the future's failure. The exception will not be propagated to the caller.

=head2 $future = repeat { CODE } until => CODE

Repeatedly calls the C<CODE> block until the C<until> condition returns a true
value. Each time the trial future completes, the C<until> condition is passed
the trial future.

 $trial_f = $code->( $previous_trial_f )
 $accept = $until->( $trial_f )

=head2 $future = repeat { CODE } foreach => ARRAY, otherwise => CODE

Calls the C<CODE> block once for each value obtained from the array, passing
in the value as the first argument (before the previous trial future). When
there are no more items left in the array, the C<otherwise> code is invoked
once and passed the last trial future, if there was one, otherwise C<undef> if
the list was originally empty. The result of the eventual future will be the
result of the future returned from C<otherwise>.

The referenced array may be modified by this operation.

 $trial_f = $code->( $item, $previous_trial_f )
 $final_f = $otherwise->( $last_trial_f )

The C<otherwise> code is optional; if not supplied then the result of the
eventual future will simply be that of the last trial.

=head2 $future = repeat { CODE } foreach => ARRAY, while => CODE, ...

=head2 $future = repeat { CODE } foreach => ARRAY, until => CODE, ...

Combines the effects of C<foreach> with C<while> or C<until>. Calls the
C<CODE> block once for each value obtained from the array, until the array is
exhausted or the given ending condition is satisfied.

If a C<while> or C<until> condition is combined with C<otherwise>, the
C<otherwise> code will only be run if the array was entirely exhausted. If the
operation is terminated early due to the C<while> or C<until> condition being
satisfied, the eventual result will simply be that of the last trial that was
executed.

=head2 $future = repeat { CODE } generate => CODE, otherwise => CODE

Calls the C<CODE> block once for each value obtained from the generator code,
passing in the value as the first argument (before the previous trial future).
When the generator returns an empty list, the C<otherwise> code is invoked and
passed the last trial future, if there was one, otherwise C<undef> if the
generator never returned a value. The result of the eventual future will be
the result of the future returned from C<otherwise>.

 $trial_f = $code->( $item, $previous_trial_f )
 $final_f = $otherwise->( $last_trial_f )

 ( $item ) = $generate->()

The generator is called in list context but should return only one item per
call. Subsequent values will be ignored. When it has no more items to return
it should return an empty list.

=cut

sub _repeat
{
   my ( $code, $return, $trialp, $cond, $sense ) = @_;

   my $prev = $$trialp;

   while(1) {
      my $trial = $$trialp ||= Future->call( $code, $prev );
      $prev = $trial;

      if( !$trial->is_ready ) {
         # defer
         $return ||= $trial->new;
         $trial->on_ready( sub {
            _repeat( $code, $return, $trialp, $cond, $sense );
         });
         return $return;
      }

      if( !$cond->( $trial ) ^ $sense ) {
         # Return result
         $return ||= $trial->new;
         $trial->on_done( $return );
         $trial->on_fail( $return );
         return $return;
      }

      # redo
      undef $$trialp;
   }
}

sub repeat(&@)
{
   my $code = shift;
   my %args = @_;

   # This makes it easier to account for other conditions
   defined($args{while}) + defined($args{until}) == 1 
      or defined($args{foreach})
      or defined($args{generate})
      or croak "Expected one of 'while', 'until', 'foreach' or 'generate'";

   if( $args{foreach} ) {
      $args{generate} and croak "Cannot use both 'foreach' and 'generate'";

      my $array = delete $args{foreach};
      $args{generate} = sub {
         @$array ? shift @$array : ();
      };
   }

   if( $args{generate} ) {
      my $generator = delete $args{generate};
      my $otherwise = delete $args{otherwise};

      # TODO: This is slightly messy as this lexical is captured by both
      #   blocks of code. Can we do better somehow?
      my $done;

      my $orig_code = $code;
      $code = sub {
         my ( $last_trial_f ) = @_;
         my $again = my ( $value ) = $generator->( $last_trial_f );

         if( $again ) {
            unshift @_, $value; goto &$orig_code;
         }

         $done++;
         if( $otherwise ) {
            goto &$otherwise;
         }
         else {
            return $last_trial_f;
         }
      };

      if( my $orig_while = delete $args{while} ) {
         $args{while} = sub {
            $orig_while->( $_[0] ) and !$done;
         };
      }
      elsif( my $orig_until = delete $args{until} ) {
         $args{while} = sub {
            !$orig_until->( $_[0] ) and !$done;
         };
      }
      else {
         $args{while} = sub { !$done };
      }
   }

   my $future = $args{return};

   my $trial;
   $args{while} and $future = _repeat( $code, $future, \$trial, $args{while}, 0 );
   $args{until} and $future = _repeat( $code, $future, \$trial, $args{until}, 1 );

   $future->on_cancel( sub { $trial->cancel } );

   return $future;
}

=head2 $future = try_repeat { CODE } ...

Currently a simple alias to C<repeat>. However, in some later version the
C<repeat> function will be changed so that if a trial future fails, then the
eventual future will immediately fail as well, making its semantics a little
closer to that of a C<while {}> loop in Perl. Code that specifically wishes
to catch failures in trial futures and retry the block should use
C<try_repeat> specifically.

=cut

*try_repeat = \&repeat;

=head2 $future = try_repeat_until_success { CODE } ...

A shortcut to calling C<try_repeat> with an ending condition that simply tests
for a successful result from a future. May be combined with C<foreach> or
C<generate>.

This function used to be called C<repeat_until_success>, and is currently
aliased as this name as well.

=cut

sub try_repeat_until_success(&@)
{
   my $code = shift;
   my %args = @_;

   # TODO: maybe merge while/until conditions one day...
   defined($args{while}) or defined($args{until})
      and croak "Cannot pass 'while' or 'until' to try_repeat_until_success";

   try_repeat( $code, while => sub { shift->failure }, %args );
}

# Legacy name
*repeat_until_success = \&try_repeat_until_success;

=head1 APPLYING A FUNCTION TO A LIST

The C<fmap> family of functions provide a way to call a block of code that
returns a L<Future> (called here an "item future") once per item in a given
list, or returned by a generator function. The C<fmap*> functions themselves
return a C<Future> to represent the ongoing operation, which completes when
every item's future has completed.

While this behaviour can also be implemented using C<repeat>, the main reason
to use an C<fmap> function is that the individual item operations are
considered as independent, and thus more than one can be outstanding
concurrently. An argument can be passed to the function to indicate how many
items to start initially, and thereafter it will keep that many of them
running concurrently until all of the items are done, or until any of them
fail. If an individual item future fails, the overall result future will be
marked as failing with the same failure, and any other pending item futures
that are outstanding at the time will be cancelled.

The following named arguments are common to each C<fmap*> function:

=over 8

=item foreach => ARRAY

Provides the list of items to iterate over, as an C<ARRAY> reference.

The referenced array may be modified by this operation.

=item generate => CODE

Provides the list of items to iterate over, by calling the generator function
once for each required item. The function should return a single item, or an
empty list to indicate it has no more items.

 ( $item ) = $generate->()

=item concurrent => INT

Gives the number of item futures to keep outstanding. By default this value
will be 1 (i.e. no concurrency); larger values indicate that multiple item
futures will be started at once.

=item return => Future

Normally, a new instance is returned by cloning the first non-immediate future
returned as an item future. By passing a new instance as the C<return>
argument, the result will be put into the given instance. This can be used to
return subclasses, or specific instances.

=back

In each case, the main code block will be called once for each item in the
list, passing in the item as the only argument:

 $item_f = $code->( $item )

The expected return value from each item's future, and the value returned from
the result future will differ in each function's case; they are documented
below.

=cut

# This function is invoked in two circumstances:
#  a) to create an item Future in a slot,
#  b) once a non-immediate item Future is complete, to check its results
# It can tell which circumstance by whether the slot itself is defined or not
sub _fmap_slot
{
   my @args = my ( $slots, $idx, $code, $generator, $collect, $results, $return ) = @_;

   while(1) {
      unless( $slots->[$idx] ) {
         # No item Future yet (case a), so create one
         my $item;
         unless( ( $item ) = $generator->() ) {
            # All out of items, so now just wait for the slots to be finished
            undef $slots->[$idx];
            defined and return $return for @$slots;

            # All the slots are done
            $return ||= Future->new;

            $return->done( @$results );
            return $return;
         }

         my $f = $slots->[$idx] = Future->call( $code, $item );

         if( $collect eq "array" ) {
            push @$results, my $r = [];
            $f->on_done( sub { @$r = @_ });
         }
         elsif( $collect eq "scalar" ) {
            push @$results, undef;
            my $r = \$results->[-1];
            $f->on_done( sub { $$r = $_[0] });
         }
      }

      my $f = $slots->[$idx];

      # Slot is non-immediate; arrange for us to be invoked again later when it's ready
      if( !$f->is_ready ) {
         $args[-1] = ( $return ||= $f->new );
         $f->on_done( sub { _fmap_slot( @args ) } );
         $f->on_fail( $return );
         return $return;
      }

      # Either we've been invoked again (case b), or the immediate Future was
      # already ready.
      if( $f->failure ) {
         $return ||= $f->new;
         $return->fail( $f->failure );
         return $return;
      }

      undef $slots->[$idx];
      # next
   }
}

sub _fmap
{
   my $code = shift;
   my %args = @_;

   my $concurrent = $args{concurrent} || 1;
   my @slots = ( undef ) x $concurrent;

   my $results = [];
   my $future = $args{return};

   my $generator;
   if( $generator = $args{generate} ) {
      # OK
   }
   elsif( my $array = $args{foreach} ) {
      $generator = sub { return unless @$array; shift @$array };
   }
   else {
      croak "Expected either 'generate' or 'foreach'";
   }

   # If any of these immediately fail, don't bother continuing
   foreach my $idx ( 0 .. $#slots ) {
      $future = _fmap_slot( \@slots, $idx, $code, $generator, $args{collect}, $results, $future );
      last if $future->is_ready;
   }

   $future->on_fail( sub {
      !defined $_ or $_->is_ready or $_->cancel for @slots;
   });
   $future->on_cancel( sub {
      $_->cancel for @slots;
   });

   return $future;
}

=head2 $future = fmap { CODE } ...

This version of C<fmap> expects each item future to return a list of zero or
more values, and the overall result will be the concatenation of all these
results. It acts like a future-based equivalent to Perl's C<map> operator.

The results are returned in the order of the original input values, not in the
order their futures complete in. Because of the intermediate storage of
C<ARRAY> references and final flattening operation used to implement this
behaviour, this function is slightly less efficient than C<fmap1> or
C<fmap_void> in cases where item futures are expected only ever to return one,
or zero values, respectively.

This function is also available under the name C<fmap_concat> to emphasise the
concatenation behaviour.

=cut

*fmap = \&fmap_concat; # alias

sub fmap_concat(&@)
{
   my $code = shift;
   my %args = @_;

   _fmap( $code, %args, collect => "array" )->then( sub {
      return Future->new->done( map { @$_ } @_ );
   });
}

=head2 $future = fmap1 { CODE } ...

This version of C<fmap> acts more like the C<map> functions found in Scheme or
Haskell; it expects that each item future returns only one value, and the
overall result will be a list containing these, in order of the original input
items. If an item future returns more than one value the others will be
discarded. If it returns no value, then C<undef> will be substituted in its
place so that the result list remains in correspondence with the input list.

=cut

sub fmap1(&@)
{
   my $code = shift;
   my %args = @_;

   _fmap( $code, %args, collect => "scalar" )
}

=head2 $future = fmap_void { CODE } ...

This version of C<fmap> does not collect any results from its item futures, it
simply waits for them all to complete. Its result future will provide no
values.

While not a map in the strictest sense, this variant is still useful as a way
to control concurrency of a function call iterating over a list of items,
obtaining its results by some other means (such as side-effects on captured
variables, or some external system).

=cut

sub fmap_void(&@)
{
   my $code = shift;
   my %args = @_;

   _fmap( $code, %args, collect => "void" )
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
