use JSON qw( decode_json );

# Doesn't matter what this is, but later tests will use it.
my $password = "s3kr1t";

my $registered_user_fixture = fixture(
   requires => [qw( first_api_client )],

   setup => sub {
      my ( $api_client ) = @_;

      $api_client->do_request_json(
         method => "POST",
         uri    => "/api/v1/register",

         content => {
            type     => "m.login.password",
            user     => "02login",
            password => $password,
         },
      )->then( sub {
         my ( $body ) = @_;

         Future->done( $body->{user_id} );
      });
   },
);

test "GET /login yields a set of flows",
   requires => [qw( first_api_client )],

   provides => [qw( can_login_password_flow )],

   check => sub {
      my ( $http ) = @_;

      $http->do_request_json(
         uri => "/api/v1/login",
      )->then( sub {
         my ( $body ) = @_;

         require_json_keys( $body, qw( flows ));
         ref $body->{flows} eq "ARRAY" or die "Expected 'flows' as a list";

         my $has_login_flow;

         foreach my $idx ( 0 .. $#{ $body->{flows} } ) {
            my $flow = $body->{flows}[$idx];

            # TODO(paul): Spec is a little vague here. Spec says that every
            #   option needs a 'stages' key, but the implementation omits it
            #   for options that have only one stage in their flow.
            ref $flow->{stages} eq "ARRAY" or defined $flow->{type} or
               die "Expected flow[$idx] to have 'stages' as a list or a 'type'";

            my $stages = $flow->{stages} || [];

            $has_login_flow++ if
               $flow->{type} eq "m.login.password" or
               @$stages == 1 && $stages->[0] eq "m.login.password";
         }

         $has_login_flow and
            provide can_login_password_flow => 1;

         Future->done(1);
      });
   };

test "POST /login can log in as a user",
   requires => [qw( first_api_client ), $registered_user_fixture,
                qw( can_login_password_flow )],

   provides => [qw( can_login first_home_server do_request_json_for do_request_json )],

   do => sub {
      my ( $http, $user_id ) = @_;

      $http->do_request_json(
         method => "POST",
         uri    => "/api/v1/login",

         content => {
            type     => "m.login.password",
            user     => $user_id,
            password => $password,
         },
      )->then( sub {
         my ( $body ) = @_;

         require_json_keys( $body, qw( access_token home_server ));

         provide can_login => 1;

         provide first_home_server => $body->{home_server};

         provide do_request_json_for => sub { die "Dead - see do_request_json_for() instead" };

         provide do_request_json => sub { die "Dead - see do_request_json_for() on \$user instead" };

         Future->done(1);
      });
   };

test "POST /login wrong password is rejected",
   requires => [qw( first_api_client ), $registered_user_fixture,
                qw( can_login_password_flow )],

   do => sub {
      my ( $http, $user_id ) = @_;

      $http->do_request_json(
         method => "POST",
         uri    => "/api/v1/login",

         content => {
            type     => "m.login.password",
            user     => $user_id,
            password => "${password}wrong",
         },
      )->main::expect_http_403->then( sub {
         my ( $resp ) = @_;

         my $body = decode_json $resp->content;

         require_json_keys( $body, qw( errcode ));

         my $errcode = $body->{errcode};

         $errcode eq "M_FORBIDDEN" or
            die "Expected errcode to be M_FORBIDDEN but was $errcode";

         Future->done(1);
      });
   };

test "POST /tokenrefresh invalidates old refresh token",
   requires => [qw( first_api_client ), $registered_user_fixture ],

   do => sub {
      my ( $http, $user_id ) = @_;

      my $first_body;

      $http->do_request_json(
         method => "POST",
         uri    => "/api/v1/login",

         content => {
            type     => "m.login.password",
            user     => $user_id,
            password => $password,
         },
      )->then( sub {
         ( $first_body ) = @_;

         $http->do_request_json(
            method => "POST",
            uri    => "/v2_alpha/tokenrefresh",

            content => {
               refresh_token => $first_body->{refresh_token},
            },
         )
      })->then(
         sub {
            my ( $second_body ) = @_;

            require_json_keys( $second_body, qw( access_token refresh_token ));

            $second_body->{$_} ne $first_body->{$_} or
               die "Expected new '$_'" for qw( access_token refresh_token );

            $http->do_request_json(
               method => "POST",
               uri    => "/v2_alpha/tokenrefresh",

               content => {
                  refresh_token => $first_body->{refresh_token},
               },
            )->main::expect_http_403;
         }
      );
   };
