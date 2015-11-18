use List::UtilsBy qw( extract_first_by );
use Future::Utils qw( repeat );

test "GET /events initially",
   requires => [ our $SPYGLASS_USER, qw( first_api_client )],

   critical => 1,

   check => sub {
      my ( $user, $http ) = @_;

      do_request_json_for( $user,
         method => "GET",
         uri    => "/api/v1/events",
         params => { timeout => 0 },
      )->then( sub {
         my ( $body ) = @_;

         require_json_keys( $body, qw( start end chunk ));
         require_json_list( $body->{chunk} );

         # We can't be absolutely sure that there won't be any events yet, so
         # don't check that.

         # Set current event-stream end point
         $user->eventstream_token = $body->{end};

         Future->done(1);
      });
   };

test "GET /initialSync initially",
   requires => [ $SPYGLASS_USER ],

   provides => [qw( can_initial_sync )],

   check => sub {
      my ( $user ) = @_;

      do_request_json_for( $user,
         method => "GET",
         uri    => "/api/v1/initialSync",
      )->then( sub {
         my ( $body ) = @_;

         require_json_keys( $body, qw( end ));

         # Spec says these are optional
         if( exists $body->{rooms} ) {
            require_json_list( $body->{rooms} );
         }
         if( exists $body->{presence} ) {
            require_json_list( $body->{presence} );
         }

         provide can_initial_sync => 1;

         push our @EXPORT, qw( matrix_initialsync );

         Future->done(1);
      });
   };

sub matrix_initialsync
{
   my ( $user, %args ) = @_;

   do_request_json_for( $user,
      method => "GET",
      uri    => "/api/v1/initialSync",

      params => {
         ( map { defined $args{$_} ? ( $_ => $args{$_} ) : () }
            qw( limit archived ) ),
      },
   );
}

# A useful function which keeps track of the current eventstream token and
#   fetches new events since it
# $room_id may be undefined, in which case it gets events for all joined rooms.
sub GET_new_events_for
{
   my ( $user, $room_id ) = @_;

   return $user->pending_get_events //=
      do_request_json_for( $user,
         method => "GET",
         uri    => "/api/v1/events",
         params => {
            from    => $user->eventstream_token,
            timeout => 500,
            room_id => $room_id
         }
      )->on_ready( sub {
         undef $user->pending_get_events;
      })->then( sub {
         my ( $body ) = @_;
         $user->eventstream_token = $body->{end};

         my @events = ( @{ $user->saved_events }, @{ $body->{chunk} } );
         @{ $user->saved_events } = ();

         Future->done( @events );
      });
}

# Some Matrix protocol helper functions

push our @EXPORT, qw( flush_events_for await_event_for );

sub flush_events_for
{
   my ( $user ) = @_;

   do_request_json_for( $user,
      method => "GET",
      uri    => "/api/v1/events",
      params => {
         timeout => 0,
      }
   )->then( sub {
      my ( $body ) = @_;
      $user->eventstream_token = $body->{end};
      @{ $user->saved_events } = ();

      Future->done;
   });
}

# Note that semantics are undefined if calls are interleaved with differing
# $room_ids for the same user.
sub await_event_for
{
   my ( $user, %params ) = @_;

   my $filter = $params{filter} || sub { 1 };
   my $room_id = $params{room_id};  # May be undefined, in which case we listen to all joined rooms.

   my $failmsg = SyTest::CarpByFile::shortmess( "Timed out waiting for an event" );

   my $f = repeat {
      # Just replay saved ones the first time around, if there are any
      my $replay_saved = !shift && scalar @{ $user->saved_events };

      ( $replay_saved
         ? Future->done( splice @{ $user->saved_events } )  # fetch-and-clear
         : GET_new_events_for( $user, $room_id )
      )->then( sub {
         my @events = @_;

         my $found = extract_first_by { $filter->( $_ ) } @events;

         # Save the rest for next time
         push @{ $user->saved_events }, @events;

         Future->done( $found );
      });
   } while => sub { !$_[0]->failure and !$_[0]->get };

   return Future->wait_any(
      $f,

      delay( 10 )
         ->then_fail( $failmsg ),
   );
}
