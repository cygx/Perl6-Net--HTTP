use Net::HTTP::Interfaces;
use Net::HTTP::Utils;

my $CRLF = Buf.new(13, 10);

class Net::HTTP::Response does Response {
    has $.status-line;
    has %.header;
    has $.body is rw;
    has %.trailer;

    proto method new(|) {*}
    multi method new(:$status-line, :%header, :$body, :%trailer, *%_) {
        self.bless(:$status-line, :%header, :$body, :%trailer, |%_);
    }
    multi method new(Blob $raw, *%_) {
        # Decodes headers to a string, and leaves the body as binary
        # i.e. `::("$?CLASS").new($socket.recv(:bin))`
        my @sep      = $CRLF.contents.Slip xx 2;

        my $sep-size = @sep.elems;
        my $split-at = $raw.grep(*, :k).first({ $raw[$^a..($^a + $sep-size - 1)] ~~ @sep }, :k);

        my $hbuf := $raw.subbuf(0, $split-at + $sep-size);
        my $bbuf := $raw.subbuf($split-at + $sep-size);
        my @header-lines = $hbuf.unpack('A*').split($CRLF.decode).grep(*.so);

        # If the status-line was passed in as a named argument, then we assume its not also in @headers.
        # Otherwise we will use the first line of @headers if it matches a status-line like string.
        my $status-line = %_<status-line> // (@header-lines.shift if @header-lines[0] ~~ self!status-line-matcher);

        my %header = @header-lines>>.split(/':' \s+/, 2)>>.hash;
        samewith(:$status-line, :%header, :body($bbuf), |%_);
    }


    method status-code { $!status-line ~~ self!status-line-matcher andthen return ~$_[0] }
    method !status-line-matcher { $ = rx/^ 'HTTP/' \d [\.\d]? \s (\d\d\d) \s/ }
}

# I'd like to put this in Net::HTTP::Utils, but there is problem with it being loaded late
role ResponseBodyDecoder {
    has $.enc-via-header;
    has $.enc-via-body;
    has $.enc-via-bom;
    has $.enc-via-force;
    has $!sniffed;

    method content-encoding {
        return $!sniffed if $!sniffed;
        self.content;
        $!sniffed;
    }

    method content {
        with self.header<Content-Type> {
            $!enc-via-header := $_.map({ sniff-content-type($_) }).first(*)
        }
        with self.body { $!enc-via-body := sniff-meta($_) }
        with self.body { $!enc-via-bom  := sniff-bom($_)  }

        try { self.body.decode($!sniffed = $!enc-via-header)   } or\
        try { self.body.decode($!sniffed = $!enc-via-body)     } or\
        try { self.body.decode($!sniffed = $!enc-via-bom)      } or\
        try { $!enc-via-force = $!sniffed = 'utf-8';   self.body.decode('utf-8') } or\
        try { $!enc-via-force = $!sniffed = 'latin-1'; self.body.unpack("A*")    } or\
        die "Don't know how to decode this content";
    }

    sub sniff-content-type(Str $header) {
        if $header ~~ /[:i 'charset=' <q=[\'\"]>? $<charset>=<[a..z A..Z 0..9 \- \_ \.]>+ $<q>?]/ {
            my $charset = ~$<charset>;
            return $charset.lc;
        }
    }

    multi sub sniff-meta(Buf $body) {
        samewith($body.subbuf(0,512).unpack("A*"));
    }
    multi sub sniff-meta(Str $body) {
        if $body ~~ /[:i '<' \s* meta \s* [<-[\>]> .]*? 'charset=' <q=[\'\"]>? $<charset>=<[a..z A..Z 0..9 \- \_ \.]>+ $<q>? .*? '>' ]/ {
            my $charset = ~$<charset>;
            return $charset.lc;
        }
    }

    multi sub sniff-bom(Str $data) { }
    multi sub sniff-bom(Blob $data) {
        given $data.subbuf(0,4).decode('latin-1') {
            when /^ 'ÿþ␀␀'  / { return 'utf-32-le'     } # no test
            when /^ '␀␀þÿ'  / { return 'utf-32-be'     } # no test
            when /^ 'þÿ'   / { return 'utf-16-be'     }
            when /^ 'ÿþ'   / { return 'utf-16-le'     }
            when /^ 'ï»¿'  / { return 'utf-8'         }
            when /^ '÷dL'  / { return 'utf-1'         } # no test
            when /^ 'Ýsfs' / { return 'utf-ebcdic'    } # no test
            when /^ '␎þÿ'   / { return 'scsu'          } # no test
            when /^ 'ûî('  / { return 'bocu-1'        } # no test
            when /^ '„1•3' / { return 'gb-18030'      } # test marked :todo :(
            when /^ '+/v' <[89/+]> / { return 'utf-7' }
        }
    }
}