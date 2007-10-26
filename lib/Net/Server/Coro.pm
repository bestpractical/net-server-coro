package Net::Server::Coro;

use strict;
use vars qw($VERSION @ISA $LOCK_EX $LOCK_UN);
use POSIX qw(WNOHANG);
use Fcntl ();
use Net::Server ();
use Net::Server::SIG qw(register_sig check_sigs);
use Coro;
use Coro::Semaphore;
use Coro::Event;
use Coro::Socket;
@ISA = qw(Net::Server);

### override-able options for this package
sub options {
  my $self = shift;
  my $prop = $self->{server};
  my $ref  = shift;

  $self->SUPER::options($ref);

  foreach ( qw(max_servers max_requests request_timeout response_timeout) ){
    $prop->{$_} = undef unless exists $prop->{$_};
    $ref->{$_} = \$prop->{$_};
  }

}

sub Coro::Socket::AUTOLOAD {
    warn $Coro::Socket::AUTOLOAD;
}
sub pre_bind {
    warn "pre_bind"
}
my $SOCK;
sub bind {
    warn "bind";
    my $self = shift;
    my $prop = $self->{server};
  foreach my $port ( @{ $prop->{port} } ){
    my $obj = $self->proto_object($prop->{host},
                                  $port,
                                  $prop->{proto},
                                  ) || next;
                                  $SOCK = $obj;
                                  #push @{ $prop->{sock} }, $obj;
  }
}

sub proto_object {
    my $self = shift;
    my ($host,$port,$proto) = @_;
    $host = '0.0.0.0' if $host eq '*';
    return Coro::Socket->new(
        LocalAddr   => $host,
        LocalPort   => $port,
        ReuseAddr   => 1,
        Listen      => 1,
    );
}


sub post_bind { warn "post_bind: $SOCK" }
my @fh;
my @pool;
my $connections = new Coro::Semaphore 500; # $MAX_CONNECTS;

use vars '$SELF';
sub handler {
   while () {
      my $prop = $SELF->{server};
      my $fh = pop @fh;
      if ($fh) {
        $prop->{connected} = 1;
        my $from = $fh->peername;
        warn "CONNECTED! ($fh - $from)";
        $prop->{client} = $fh;
        $SELF->run_client_connection;
        last if $SELF->done;
        $prop->{connected} = 0;
         close $fh;
         $connections->up;
      } else {
         last if @pool >= 20; #$MAX_POOL;
         push @pool, $Coro::current;
         schedule;
      }
   }
}

### prepare for connections
sub loop {
    my $self = $SELF = shift;
    my $prop = $self->{server};

    async {
        while (1) {
            $connections->down;
            warn "CC";
            push @fh, scalar $SOCK->accept;
            warn "GOT: @fh\n";
            if (@pool) {
                (pop @pool)->ready;
            } else {
                async \&handler;
            }

        }
    };
    schedule;
    loop;
}

*FileHandle::peername = *Coro::Socket::peername;

1;
