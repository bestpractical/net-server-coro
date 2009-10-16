use strict;
use warnings;

package Net::Server::Coro;

use vars qw($VERSION);
use EV;
use Coro;
use base qw(Net::Server);
use Net::Server::Proto::Coro;

$VERSION = 0.5;

=head1 NAME

Net::Server::Coro - A co-operative multithreaded server using Coro

=head1 SYNOPSIS

    use Coro;
    use base qw/Net::Server::Coro/;

    __PACKAGE__->new->run;

    sub process_request {
       ...
       cede;
       ...
    }

=head1 DESCRIPTION

L<Net::Server::Coro> implements multithreaded server for the
L<Net::Server> architecture, using L<Coro> and L<Coro::Socket> to make
all reads and writes non-blocking.  Additionally, it supports
non-blocking SSL negotiation.

=head1 METHODS

Most methods are inherited from L<Net::Server> -- see it for further
usage details.

=cut

=head2 new

Create new Net::Server::Coro object. It accepts these parameters (in
addition to L<Net::Server> parameters):

=item server_cert

Path to the SSL certificate that the server should use. This can be
either relative or absolute path.  Defaults to
F<certs/server-cert.pem>

=item server_key

Path to the SSL certificate key that the server should use. This can
be either relative or absolute path.  Defaults to
F<certs/server-key.pem>

=cut

sub new {
    my $class = shift;
    my %args = @_;
    my $self = $class->SUPER::new(@_);

    # Set up certificates
    $self->server_cert($args{'server_cert'}) if exists $args{'server_cert'};
    $self->server_key($args{'server_key'})   if exists $args{'server_key'};

    return $self;
}

sub post_bind_hook {
    my $self = shift;
    my $prop = $self->{server};
    delete $prop->{select};

    $prop->{sock} = [ map { $self->make_coro_socket($_) } @{ $prop->{sock} } ];
}

=head2 make_coro_socket SOCKET

Takes an L<IO::Socket> or L<Net::Server::Proto> object, and converts
it into a L<Net::Server::Proto::Coro> object.

=cut

sub make_coro_socket {
    my $self = shift;
    my $socket = shift;

    my @extra;
    if ( $socket->isa("IO::Socket::SSL") ) {
        $socket = bless $socket, "Net::Server::Proto::TCP";
        @extra = ( expects_ssl => 1 );
    }

    $socket = Net::Server::Proto::Coro->new_from_fh(
        $socket,
        forward_class => ref($socket),
        server_cert => $self->server_cert,
        server_key => $self->server_key,
        @extra
    );
    return $socket;
}

sub coro_instance {
    my $self = shift;
    my $fh   = shift;
    my $prop = $self->{server};
    $Coro::current->desc("Active connection");
    $prop->{client} = $fh;
    $self->run_client_connection;
    close $fh;
}

# We override this to do nothing, or Net::Server closes
# $self->{server}{client} -- which is he most recent connection, not
# necessarily the current connection.  We also don't want the
# STDERR/STDOUT redirection.
sub post_process_request {}

=head2 loop

The main loop uses starts a number of L<Coro> coroutines:

=over 4

=item *

One for each listening socket.

=item *

One for each active connection.  Since these may respawn on a firlay
frequent basis, L<Coro/async_pool> is used to maintain a pool of
coroutines.

=item *

The L<EV> event loop.

=back

=cut

sub loop {
    my $self = shift;
    my $prop = $self->{server};
    $prop->{no_client_stdout} = 1;

    for my $socket ( @{ $prop->{sock} } ) {
        async {
            $Coro::current->desc("Listening on port @{[$socket->sockport]}");
            while (1) {
                my $accepted = scalar $socket->accept;
                next unless $accepted;
                async_pool \&coro_instance, $self, $accepted;
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
        EV::loop() while 1;
    };

    schedule;
}

=head2 server_cert [PATH]

Gets or sets the path fo the SSL certificate used by the server.

=cut

sub server_cert {
    my $self = shift;
    if (@_) {
        my $cert = shift;
        die "SSL certificate file ($cert) is not readable!" unless -r $cert;
        $self->{'server_cert'} = $cert;
    }
    return $self->{'server_cert'};
}

=head2 server_key [PATH]

Gets or sets the path fo the SSL key file used by the server.

=cut

sub server_key {
    my $self = shift;
    if (@_) {
        my $key = shift;
        die "SSL key file ($key) is not readable!" unless -r $key;
        $self->{'server_key'} = $key;
    }
    return $self->{'server_key'};
}

=head1 DEPENDENCIES

L<Coro>, L<EV>, L<Net::Server>

=head1 BUGS AND LIMITATIONS

Generally, all those of L<Coro>.  Please report any bugs or feature
requests specific to L<Net::Server::Coro> to
C<bug-net-server-coro@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.

=head1 AUTHORS

Alex Vandiver C<< <alexmv@bestpractical.com> >>; code originally from
Audrey Tang C<< <cpan@audreyt.org> >>

=head1 COPYRIGHT

Copyright 2006 by Audrey Tang <cpan@audreyt.org>

Copyright 2007-2008 by Best Practical Solutions

This software is released under the MIT license cited below.

=head2 The "MIT" License

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut

## Due to outstanding rt.cpan.org #31437 for Net::Server
use Net::Server::Proto::TCP;

package # Hide from PAUSE indexer
    Net::Server::Proto::TCP;
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
