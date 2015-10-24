use Net::HTTP::Interfaces;
use Net::HTTP::Utils;
use Net::HTTP::Dialer;

# Higher level HTTP transport for creating a custom HTTP::Client
# similar to ::GET and ::POST but made for reuse (connection caching and other state control)
class Net::HTTP::Transport does RoundTripper {
    also does Net::HTTP::Dialer;

    # mix in a proxy role and the host and request target url are set appropriately automatically
    # method proxy { ::('Net::HTTP::URL').new("http://proxy-lord.org") }

    method round-trip(Request $req, Response ::RESPONSE = Net::HTTP::Response --> Response) {
        self!hijack($req);

        # MAKE REQUEST
        my $socket = self.dial($req) but IO::Socket::HTTP;
        $socket.print(~$req);

        # GET AND PARSE RESPONSE
        my @header = $socket.lines(:bin).map: {$_ or last}
        my $body   = $socket.recv(:bin);

        my $res    = RESPONSE.new($body, @header);

        $socket.close() if $res.header<connection>.defined && $res.header<connection> ~~ /[:i close]/;

        $res;
    }

    method !hijack(Request $req) {
        my $header := $req.header;
        my $proxy   = self.?proxy;

        # set the host field to either an optional proxy's url host or the request's url host
        $header<host>  = $proxy ?? $proxy.host !! $req.url.host;

        # override any possible default start-line() method behavior of using a relative request target url if $proxy
        $req does role :: { method path {$ = ~$req.url } } if $proxy;

        # automatically handle content-length setting
        $header<content-length> = !$req.body ?? 0 !! $req.body ~~ Buf ?? $req.body.bytes !! $req.body.encode.bytes;

        # default to closed connections
        $header<connection> //= 'Close';
    }
}
