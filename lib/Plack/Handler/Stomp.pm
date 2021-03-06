package Plack::Handler::Stomp;
use Moose;
use MooseX::Types::Moose qw(Bool);
use Plack::Handler::Stomp::Types qw(Logger PathMap);
use Net::Stomp::MooseHelpers::Types qw(NetStompish);
use Plack::Handler::Stomp::PathInfoMunger 'munge_path_info';
use Plack::Handler::Stomp::Exceptions;
use Net::Stomp::MooseHelpers::Exceptions;
use namespace::autoclean;
use Try::Tiny;
use Plack::Util;

with 'Net::Stomp::MooseHelpers::CanConnect' => { -version => '2.6' };
with 'Net::Stomp::MooseHelpers::CanSubscribe' => { -version => '2.6' };
with 'Net::Stomp::MooseHelpers::ReconnectOnFailure';

# ABSTRACT: adapt STOMP to (almost) HTTP, via Plack

=head1 SYNOPSIS

  my $runner = Plack::Handler::Stomp->new({
    servers => [ { hostname => 'localhost', port => 61613 } ],
    subscriptions => [
      { destination => '/queue/plack-handler-stomp-test' },
      { destination => '/topic/plack-handler-stomp-test',
        headers => {
            selector => q{custom_header = '1' or JMSType = 'test_foo'},
        },
        path_info => '/topic/ch1', },
      { destination => '/topic/plack-handler-stomp-test',
        headers => {
            selector => q{custom_header = '2' or JMSType = 'test_bar'},
        },
        path_info => '/topic/ch2', },
    ],
  });
  $runner->run(MyApp->get_app());

=head1 DESCRIPTION

Sometimes you want to use your very nice web-application-framework
dispatcher, module loading mechanisms, etc, but you're not really
writing a web application, you're writing a ActiveMQ consumer. In
those cases, this module is for you.

This module is inspired by L<Catalyst::Engine::Stomp>, but aims to be
usable by any PSGI application.

=head2 Roles Consumed

We consume L<Net::Stomp::MooseHelpers::CanConnect> and
L<Net::Stomp::MooseHelpers::CanSubscribe>. Read those modules'
documentation to see how to configure servers and subscriptions.

=attr C<logger>

A logger object used by thes handler. Not to be confused by the logger
used by the application (either internally, or via a Middleware). Can
be any object that can C<debug>, C<info>, C<warn>, C<error>. Defaults
to an instance of L<Net::Stomp::StupidLogger>. This logger is passed
on to the L<Net::Stomp> object held in C<connection> (see
L<Net::Stomp::MooseHelpers::CanConnect>).

=cut

has logger => (
    is => 'rw',
    isa => Logger,
    lazy_build => 1,
);
sub _build_logger {
    require Net::Stomp::StupidLogger;
    Net::Stomp::StupidLogger->new();
}

sub _build_connection {
    my ($self) = @_;

    return $self->connection_builder->({
        %{$self->extra_connection_builder_args},
        logger => $self->logger,
        hosts => $self->servers,
    });
}

=attr C<destination_path_map>

A hashref mapping destinations (queues, topics, subscription ids) to
URI paths to send to the application. You should not modify this.

=cut

has destination_path_map => (
    is => 'ro',
    isa => PathMap,
    default => sub { { } },
);

=attr C<one_shot>

If true, exit after the first message is consumed. Useful for testing,
defaults to false.

=cut

has one_shot => (
    is => 'rw',
    isa => Bool,
    default => 0,
);

=method C<run>

Given a PSGI application, loops forever:

=over 4

=item *

connect to a STOMP server (see
L<connect|Net::Stomp::MooseHelpers::CanConnect/connect> and
L<servers|Net::Stomp::MooseHelpers::CanConnect/servers> in
L<Net::Stomp::MooseHelpers::CanConnect>)

=item *

subscribe to whatever needed (see
L<subscribe|Net::Stomp::MooseHelpers::CanSubscribe/subscribe> and
L<subscriptions|Net::Stomp::MooseHelpers::CanSubscribe/subscriptions>
in L<Net::Stomp::MooseHelpers::CanSubscribe>)

=item *

consume STOMP frames in an inner loop (see L</frame_loop>)

=back

If the application throws an exception, the loop exits re-throwing the
exception. If the STOMP connection has problems, the loop is repeated
with a different server (see
L<next_server|Net::Stomp::MooseHelpers::CanConnect/next_server> in
L<Net::Stomp::MooseHelpers::CanConnect>).

If L</one_shot> is set, this function exits after having consumed
exactly 1 frame.

=cut

sub run {
    my ($self, $app) = @_;

    my $exception;
    $self->reconnect_on_failure(
        sub {
        try {
            $self->subscribe();

            $self->frame_loop($app);
        } catch {
            $exception = $_;
        };
        if ($exception) {
            if (!blessed $exception) {
                $exception = "unhandled exception $exception";
                return;
            }
            if ($exception->isa('Plack::Handler::Stomp::Exceptions::AppError')) {
                return;
            }
            if ($exception->isa('Plack::Handler::Stomp::Exceptions::UnknownFrame')) {
                return;
            }
            if ($exception->isa('Plack::Handler::Stomp::Exceptions::OneShot')) {
                $exception=undef;
                return;
            }
            die $exception;
        }
    });
    die $exception if defined $exception;
    return;
}

=method C<frame_loop>

Loop forever receiving frames from the STOMP connection. Call
L</handle_stomp_frame> for each frame.

If L</one_shot> is set, this function exits after having consumed
exactly 1 frame.

=cut

sub frame_loop {
    my ($self,$app) = @_;

    while (1) {
        my $frame = $self->connection->receive_frame();
        if(!$frame || !ref($frame)) {
            Net::Stomp::MooseHelpers::Exceptions::Stomp->throw({
                stomp_error => 'empty frame received',
            });
        }
        $self->handle_stomp_frame($app, $frame);

        Plack::Handler::Stomp::Exceptions::OneShot->throw()
              if $self->one_shot;
    }
}

=method C<handle_stomp_frame>

Delegates the handling to L</handle_stomp_message>,
L</handle_stomp_error>, L</handle_stomp_receipt>, or throws
L<Plack::Handler::Stomp::Exceptions::UnknownFrame> if the frame is of
some other kind. If you want to handle different kind of frames (maybe
because you have some non-standard STOMP server), you can just
subclass and add methods; for example, to handle C<STRANGE> frames,
add a C<handle_stomp_strange> method.

=cut

sub handle_stomp_frame {
    my ($self, $app, $frame) = @_;

    my $command = $frame->command();
    my $method = $self->can("handle_stomp_\L$command");
    if ($method) {
        $self->$method($app, $frame);
    }
    else {
        Plack::Handler::Stomp::Exceptions::UnknownFrame->throw(
            {frame=>$frame}
        );
    }
}

=method C<handle_stomp_error>

Logs the error via the L</logger>, level C<warn>.

=cut

sub handle_stomp_error {
    my ($self, $app, $frame) = @_;

    my $error = $frame->headers->{message};
    $self->logger->warn($error);
}

=method C<handle_stomp_message>

Calls L</build_psgi_env> to convert the STOMP message into a PSGI
environment.

The environment is then passed to L</process_the_message>, and the
frame is acknowledged.

=cut

sub handle_stomp_message {
    my ($self, $app, $frame) = @_;

    my $env = $self->build_psgi_env($frame);
    try {
        $self->process_the_message($app,$env);

        $self->connection->ack({ frame => $frame });
    } catch {
        Plack::Handler::Stomp::Exceptions::AppError->throw({
            app_error => $_
        });
    };
}

=method C<process_the_message>

Runs a PSGI environment through the application, then flattens the
response body into a simple string.

The response so flattened is sent back via L</maybe_send_reply>.

=cut

sub process_the_message {
    my ($self,$app,$env) = @_;

    my $res = $app->($env);

    my $flattened_response=[];
    my $cb = sub { $flattened_response->[2].=$_[0] };

    my $response_handler = sub {
        my ($response) = @_;

        $flattened_response->[0]=$response->[0];
        $flattened_response->[1]=$response->[1];

        my $body=$response->[2];
        if (defined $body) {
            Plack::Util::foreach($body, $cb);
        }
        else {
            return Plack::Util::inline_object(
                write => $cb,
                close => sub { },
            );
        }
    };

    if (ref $res eq 'ARRAY') {
        $response_handler->($res);
    }
    elsif (ref $res eq 'CODE') {
        $res->($response_handler);
    }
    else {
        Plack::Handler::Stomp::Exceptions::AppError->throw({
            app_error => "Bad response $res"
        });
    }

    $self->maybe_send_reply($flattened_response);

    return;
}

=method C<handle_stomp_receipt>

Logs (level C<debug>) the receipt id. Nothing else is done with
receipts.

=cut

sub handle_stomp_receipt {
    my ($self, $app, $frame) = @_;

    $self->logger->debug('ignored RECEIPT frame for '
                             .$frame->headers->{'receipt-id'});
}

=method C<maybe_send_reply>

Calls L</where_should_send_reply> to determine if to send a reply, and
where. If it returns a true value, L</send_reply> is called to
actually send the reply.

=cut

sub maybe_send_reply {
    my ($self, $response) = @_;

    my $reply_to = $self->where_should_send_reply($response);
    if ($reply_to) {
        $self->send_reply($response,$reply_to);
    }

    return;
}

=method C<where_should_send_reply>

Returns the header C<X-Reply-Address> or C<X-STOMP-Reply-Address> from
the response.

=cut

sub where_should_send_reply {
    my ($self, $response) = @_;

    return Plack::Util::header_get($response->[1],
                                   'X-Reply-Address')
        || Plack::Util::header_get($response->[1],
                                   'X-STOMP-Reply-Address')
}

=method C<send_reply>

Converts the PSGI response into a STOMP frame, by removing the prefix
C<x-stomp-> from the key of header fields that have it, removing
entirely header fields that don't, and stringifying the body.

Then sends the frame.

=cut

sub send_reply {
    my ($self, $response, $reply_address) = @_;

    my $reply_queue = '/remote-temp-queue/' . $reply_address;

    my $content = '';
    unless (Plack::Util::status_with_no_entity_body($response->[0])) {
        # pre-flattened, see L</process_the_message>
        $content = $response->[2];
    }

    my %reply_hh = ();
    while (my ($k,$v) = splice @{$response->[1]},0,2) {
        $k=lc($k);
        next if $k eq 'x-stomp-reply-address';
        next if $k eq 'x-reply-address';
        next unless $k =~ s{^x-stomp-}{};

        $reply_hh{lc($k)} = $v;
    }

    $self->connection->send({
        %reply_hh,
        destination => $reply_queue,
        body => $content
    });

    return;
}

=method C<subscribe_single>

C<after> modifier on the method provided by
L<Net::Stomp::MooseHelpers::CanSubscribe>.

It sets the L</destination_path_map> to map the destination and the
subscription id to the C<path_info> slot of the L</subscriptions>
element, or to the destination itself if C<path_info> is not defined.

=cut

after subscribe_single => sub {
    my ($self,$sub,$headers) = @_;

    my $destination = $headers->{destination};
    my $sub_id = $headers->{id};

    $self->destination_path_map->{$destination} =
        $self->destination_path_map->{"/subscription/$sub_id"} =
            $sub->{path_info} || $destination;

    return;
};

=method C<build_psgi_env>

Builds a PSGI environment from the message, like:

  # server
  SERVER_NAME => 'localhost',
  SERVER_PORT => 0,
  SERVER_PROTOCOL => 'STOMP',

  # client
  REQUEST_METHOD => 'POST',
  REQUEST_URI => $path_info,
  SCRIPT_NAME => '',
  PATH_INFO => $path_info,
  QUERY_STRING => '',

  # broker
  REMOTE_ADDR => $server_hostname,

  # http
  HTTP_USER_AGENT => 'Net::Stomp',
  CONTENT_LENGTH => length($body),
  CONTENT_TYPE => $content-type,

  # psgi
  'psgi.version' => [1,0],
  'psgi.url_scheme' => 'http',
  'psgi.multithread' => 0,
  'psgi.multiprocess' => 0,
  'psgi.run_once' => 0,
  'psgi.nonblocking' => 0,
  'psgi.streaming' => 1,

In addition, reading from C<psgi.input> will return the message body,
and writing to C<psgi.errors> will log via the L</logger> at level
C<error>.

Finally, every header in the STOMP message will be available in the
"namespace" C<jms.>, so for example the message type is in
C<jms.type>.

The C<$path_info> is obtained from the L</destination_path_map>
(i.e. from the C<path_info> subscription options) passed through
L<munge_path_info|Plack::Handler::Stomp::PathInfoMunger/munge_path_info>.

=cut

sub build_psgi_env {
    my ($self, $frame) = @_;

    my $destination = $frame->headers->{destination};
    my $sub_id = $frame->headers->{subscription};

    my $path_info;
    if (defined $sub_id) {
        $path_info = $self->destination_path_map->{"/subscription/$sub_id"}
    };
    $path_info ||= $self->destination_path_map->{$destination};
    if ($path_info) {
        $path_info = munge_path_info(
            $path_info,
            $self->current_server,
            $frame,
        );
    }
    $path_info ||= $destination; # should not really be needed

    use bytes;

    my $env = {
        # server
        SERVER_NAME => 'localhost',
        SERVER_PORT => 0,
        SERVER_PROTOCOL => 'STOMP',

        # client
        REQUEST_METHOD => 'POST',
        REQUEST_URI => $path_info,
        SCRIPT_NAME => '',
        PATH_INFO => $path_info,
        QUERY_STRING => '',

        # broker
        REMOTE_ADDR => $self->current_server->{hostname},

        # http
        HTTP_USER_AGENT => 'Net::Stomp',
        CONTENT_LENGTH => length($frame->body),
        CONTENT_TYPE => ( $frame->headers->{'content-type'} || 'application/octet-stream' ),

        # psgi
        'psgi.version' => [1,0],
        'psgi.url_scheme' => 'http',
        'psgi.multithread' => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once' => 0,
        'psgi.nonblocking' => 0,
        'psgi.streaming' => 1,
        'psgi.input' => do {
            open my $input, '<', \($frame->body);
            $input;
        },
        'psgi.errors' => Plack::Util::inline_object(
            print => sub { $self->logger->error(@_) },
        ),
    };

    if ($frame->headers) {
        for my $header (keys %{$frame->headers}) {
            $env->{"jms.$header"} = $frame->headers->{$header};
        }
    }

    return $env;
}

__PACKAGE__->meta->make_immutable;

=head1 EXAMPLES

You can find examples of use in the tests, or at
https://github.com/dakkar/CatalystX-StompSampleApps

=cut

1;
