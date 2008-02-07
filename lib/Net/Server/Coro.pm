package Net::Server::Coro;

use strict;
use warnings;
use vars qw($VERSION);
use EV;
use Coro;
use Coro::Semaphore;
use Coro::Handle;
use Coro::Socket;
use base qw(Net::Server);

my $connections = new Coro::Semaphore 500;    # $MAX_CONNECTS;
use vars qw/$SELF @FH @POOL/;

no warnings 'redefine';

sub Coro::Handle::accept {
    my ( $peername, $fh );
    while () {
        ( $fh, $peername ) = tied( ${ $_[0] } )->[0]->accept;
        if ($peername) {
            my $socket
                = $_[0]->new_from_fh( $fh,
                forward_class => tied( ${ $_[0] } )->[7] );
            return wantarray ? ( $socket, $peername ) : $socket;
        }

        return unless $!{EAGAIN};

        $_[0]->readable or return;
    }
}

sub post_bind_hook {
    my $self = shift;
    my $prop = $self->{server};
    $prop->{sock}
        = [ map { make_coro_socket($_) } @{ $prop->{sock} } ];
}

sub make_coro_socket {
    my $socket = shift;
    my $proto = $socket->NS_proto;
    $socket = Coro::Socket->new_from_fh( $socket, forward_class => ref $socket );
    $socket->NS_proto($proto);
    return $socket;
}

sub get_client_info { }

sub handler {
    while (1) {
        my $prop = $SELF->{server};
        my $fh   = pop @FH;
        if ($fh) {
            $Coro::current->desc("Active connection");
            $prop->{connected} = 1;
            $prop->{client} = $fh;
            $SELF->run_client_connection;
            last if $SELF->done;
            $prop->{connected} = 0;
            close $fh;
            $connections->up;
        } else {
            last if @POOL >= 20;    #$MAX_POOL;
            push @POOL, $Coro::current;
            $Coro::current->desc("Idle connection");
            schedule;
        }
    }
}

### prepare for connections
sub loop {
    my $self = $SELF = shift;
    my $prop = $self->{server};

    for my $socket ( @{ $prop->{sock} } ) {
        async {
            $Coro::current->desc("Listening on port @{[$socket->sockport]}");
            while (1) {
                $connections->down;
                my $accepted = scalar $socket->accept;
                next unless $accepted;
                push @FH, $accepted;
                if (@POOL) {
                    ( pop @POOL )->ready;
                } else {
                    async \&handler;
                }

            }
        };
    }

    async {
        # We want this to be higher priority so it gets timeslices
        # when other things cede; this guarantees that we notice
        # socket activity and deal.
        $Coro::current->prio(3);
        $Coro::current->desc("Event loop");

        # EV needs to service something before we notice signals.
        # This interrupts the event loop every 10 seconds to force it
        # to check if we got sent a SIGINT, for instance.  Otherwise
        # it would hang until it got an I/O interrupt.
        my $death_notice = EV::timer(10, 10, sub {});
        while (1) {
            EV::loop( );
        }
    };

    schedule;
}

1;
