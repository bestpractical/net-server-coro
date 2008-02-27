package Net::Server::Coro;

use strict;
use warnings;
use vars qw($VERSION);
use EV;
use Coro;
use base qw(Net::Server);
use Net::Server::Proto::Coro;

$VERSION = 0.1;

use vars qw/$SELF @FH/;

sub post_bind_hook {
    my $self = shift;
    my $prop = $self->{server};
    $prop->{sock} = [ map { make_coro_socket($_) } @{ $prop->{sock} } ];
}

sub make_coro_socket {
    my $socket = shift;
    my @extra;
    if ( $socket->isa("IO::Socket::SSL") ) {
        $socket = bless $socket, "Net::Server::Proto::TCP";
        @extra = ( expects_ssl => 1 );
    }
    $socket = Net::Server::Proto::Coro->new_from_fh(
        $socket,
        forward_class => ref($socket),
        @extra
    );
    return $socket;
}

sub handler {
    my $fh   = shift;
    my $prop = $SELF->{server};
    $Coro::current->desc("Active connection");
    $prop->{client} = $fh;
    $SELF->run_client_connection;
    close $fh;
}

### prepare for connections
sub loop {
    my $self = $SELF = shift;
    my $prop = $self->{server};

    for my $socket ( @{ $prop->{sock} } ) {
        async {
            $Coro::current->desc("Listening on port @{[$socket->sockport]}");
            while (1) {
                my $accepted = scalar $socket->accept;
                next unless $accepted;
                async_pool \&handler, $accepted;
            }
        };
    }

    async {

        # We want this to be higher priority so it gets timeslices
        # when other things cede; this guarantees that we notice
        # socket activity and deal.
        $Coro::current->prio(3);
        $Coro::current->desc("Event loop");

        # Use EV signal handlers;
        my @shutdown = map EV::signal( $_ => sub { $self->server_close; } ),
            qw/INT TERM QUIT/;
        my $hup = EV::signal( HUP => sub { $self->sig_hup } );
        while (1) {
            EV::loop();
        }
    };

    schedule;
}

## Due to outstanding patches for Net::Server
use Net::Server::Proto::TCP;

package Net::Server::Proto::TCP;
no warnings 'redefine';

sub accept {
    my $sock = shift;
    my ( $client, $peername ) = $sock->SUPER::accept();

    ### pass items on
    if ($peername) {
        $client->NS_proto( $sock->NS_proto );
    }

    return wantarray ? ( $client, $peername ) : $client;
}

1;
