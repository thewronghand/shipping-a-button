#!/usr/bin/perl
# shipping-a-button — Chapter 0: the baseline.
#
# "One Perl script and a cron job." No containers, no YAML, no dependencies
# beyond core Perl. Everything the dashboard needs lives in this file:
#
#   perl button.pl generate [--seed N]  synthetic Acme Payments data -> data/
#   perl button.pl build                pages, statements, API, counter -> out/
#   perl button.pl serve [--port N]     static HTTP server over out/, logs to logs/
#   perl button.pl golden               write the canonical figures -> ../golden/
#   perl button.pl verify               check out/ against ../golden/
#
# The cron job runs `build` every minute. The button counter (FR-4) is derived
# from the server's access log with a regular expression, as is traditional.
#
# This file is FROZEN after Chapter 0 (README P-4).

use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Spec;
use Time::Local qw(timegm);
use POSIX qw(strftime);
use IO::Socket::INET;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use File::Glob qw(bsd_glob);
use File::Find qw(find);
use Fcntl qw(:flock);

my $DATA   = "$Bin/data";
my $OUT    = "$Bin/out";
my $LOGS   = "$Bin/logs";
my $GOLDEN = "$Bin/../golden";

my $DEFAULT_SEED = 20261012;
my $FIRST_DAY    = '2026-07-01';
my $LAST_DAY     = '2026-09-30';
my $SETTLEMENT_LAG_DAYS = 2;

my $JSON = JSON::PP->new->canonical(1)->pretty(1);

my %COMMANDS = (
    generate => \&cmd_generate,
    build    => \&cmd_build,
    serve    => \&cmd_serve,
    golden   => \&cmd_golden,
    verify   => \&cmd_verify,
);


# ---------------------------------------------------------------------------
# Deterministic randomness
#
# Park–Miller "minimal standard" generator. Perl's own rand() is not guaranteed
# to match across builds, and every later chapter must reproduce these figures
# exactly. All intermediate values stay below 2^47, so 64-bit integers suffice.
# ---------------------------------------------------------------------------

my $rng_state;

sub seed_rng {
    my ($seed) = @_;
    die "this script needs a perl with 64-bit integers\n" unless ~0 > 2**47;
    $rng_state = $seed % 2147483647;
    $rng_state = 1 if $rng_state <= 0;
}

sub next_rng {
    $rng_state = ($rng_state * 48271) % 2147483647;
    return $rng_state;
}

sub rand_int {    # inclusive
    my ($lo, $hi) = @_;
    return $lo + next_rng() % ($hi - $lo + 1);
}

sub rand_pick {
    my ($list) = @_;
    return $list->[ rand_int(0, $#$list) ];
}

# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

my @PLACE = qw(Harbor Maple Granite Willow Copper Juniper Linden Saffron Cobalt Meadow Ember Hollow);
my @TRADE = ('Coffee', 'Bakery', 'Books', 'Florist', 'Hardware', 'Noodle Bar',
             'Bicycles', 'Records', 'Tailor', 'Pharmacy', 'Stationery', 'Grocer');

sub cmd_generate {
    my (%opt) = @_;
    my $seed = $opt{seed} // $DEFAULT_SEED;
    seed_rng($seed);
    make_path($DATA);

    # Hierarchy: 3 distributors x 2 agencies x 3 merchants = 18 merchants.
    my @merchants;
    my %used_name;
    for my $d (1 .. 3) {
        my $dist_id   = sprintf 'D%02d', $d;
        my $dist_name = rand_pick(\@PLACE) . ' Distribution';
        for my $a (1 .. 2) {
            my $agency_id   = sprintf 'A%02d', ($d - 1) * 2 + $a;
            my $agency_name = rand_pick(\@PLACE) . ' Agency';
            for (1 .. 3) {
                my $name;
                do { $name = rand_pick(\@PLACE) . ' ' . rand_pick(\@TRADE) } while $used_name{$name}++;
                push @merchants, {
                    merchant_id      => sprintf('M%03d', scalar(@merchants) + 1),
                    merchant_name    => $name,
                    agency_id        => $agency_id,
                    agency_name      => $agency_name,
                    distributor_id   => $dist_id,
                    distributor_name => $dist_name,
                    fee_bp           => 150 + 5 * rand_int(0, 40),    # 1.50% .. 3.50%
                };
            }
        }
    }

    my @mcols = qw(merchant_id merchant_name agency_id agency_name distributor_id distributor_name fee_bp);
    write_csv("$DATA/merchants.csv", \@mcols, [ map { my $m = $_; [ map { $m->{$_} } @mcols ] } @merchants ]);

    my @tcols = qw(tx_id merchant_id date time method status amount);
    my @rows;
    my $seq = 0;
    for my $date (date_range($FIRST_DAY, $LAST_DAY)) {
        for my $m (@merchants) {
            my $n = rand_int(20, 120);
            for (1 .. $n) {
                my $roll   = rand_int(1, 100);
                my $method = $roll <= 70 ? 'card' : $roll <= 85 ? 'transfer' : 'easypay';
                my $status = rand_int(1, 100) <= 3 ? 'cancelled' : 'approved';
                my $amount = rand_int(10, 5000) * 100;    # KRW 1,000 .. 500,000
                my $time   = sprintf '%02d:%02d:%02d', rand_int(0, 23), rand_int(0, 59), rand_int(0, 59);
                push @rows, [ sprintf('T%07d', ++$seq), $m->{merchant_id}, $date, $time, $method, $status, $amount ];
            }
        }
    }
    write_csv("$DATA/transactions.csv", \@tcols, \@rows);

    printf "generated %d merchants, %d transactions (seed %d)\n", scalar @merchants, scalar @rows, $seed;
}

# ---------------------------------------------------------------------------
# Figures
#
# Rules (shared by every chapter):
#   - input is data/merchants.csv and data/transactions.csv, as pinned by
#     golden/data.sha256. The files are not committed; every chapter obtains
#     them the same way: `perl baseline/button.pl generate` (default seed,
#     core Perl only), then check them against golden/data.sha256. Later
#     chapters consume these files; they need not reimplement the generator.
#     (The `time` and `method` columns are carried but affect no figure.)
#   - only approved transactions count; cancelled ones are ignored entirely
#   - fee per transaction = floor(amount * fee_bp / 10000), integer arithmetic
#     only (KRW; the sub-won remainder is truncated)
#   - daily fee = sum of per-transaction fees (never a fee on the daily total)
#   - payout = amount - fee
#   - settlement date = transaction date + 2 calendar days
#   - a period is a calendar month of the TRANSACTION date (not the settlement
#     date): a 07-30 transaction settles on 08-01 but belongs to 2026-07
#   - the list of periods is the set of months containing at least one
#     approved transaction (across all merchants)
#
# Statement CSV format (byte-exact; compared by golden/statements.sha256):
#   - UTF-8, LF line endings, no BOM, no quoting
#   - header: date,settlement_date,transactions,amount,fee,payout
#   - one row per day with at least one approved transaction, ascending by date
#   - final row: TOTAL,,<transactions>,<amount>,<fee>,<payout>
#   - a period with no approved transactions is the header plus TOTAL,,0,0,0,0
# ---------------------------------------------------------------------------

sub load_figures {
    my $merchants = read_csv("$DATA/merchants.csv");
    my %by_id = map { $_->{merchant_id} => $_ } @$merchants;

    my %daily;    # merchant_id -> date -> {transactions, amount, fee}
    my $txs = read_csv("$DATA/transactions.csv");
    for my $t (@$txs) {
        next unless $t->{status} eq 'approved';
        my $m   = $by_id{ $t->{merchant_id} } or die "unknown merchant $t->{merchant_id}\n";
        my $fee = fee_for($t->{amount}, $m->{fee_bp});
        my $day = $daily{ $t->{merchant_id} }{ $t->{date} } //= { transactions => 0, amount => 0, fee => 0 };
        $day->{transactions}++;
        $day->{amount} += $t->{amount};
        $day->{fee}    += $fee;
    }

    my %periods;
    for my $mid (keys %daily) {
        for my $date (keys %{ $daily{$mid} }) {
            my $day = $daily{$mid}{$date};
            $day->{date}            = $date;
            $day->{settlement_date} = add_days($date, $SETTLEMENT_LAG_DAYS);
            $day->{payout}          = $day->{amount} - $day->{fee};
            my ($period) = $date =~ /^(\d{4}-\d{2})/;
            push @{ $periods{$mid}{$period} }, $day;
        }
    }

    my @periods_sorted = sort { $a cmp $b } keys %{ { map { %{ $periods{$_} } } keys %periods } };
    for my $mid (keys %periods) {
        for my $p (keys %{ $periods{$mid} }) {
            $periods{$mid}{$p} = [ sort { $a->{date} cmp $b->{date} } @{ $periods{$mid}{$p} } ];
        }
    }

    return {
        merchants => [ sort { $a->{merchant_id} cmp $b->{merchant_id} } @$merchants ],
        periods   => \@periods_sorted,
        daily     => \%periods,    # merchant_id -> period -> [days]
    };
}

# Integer division throughout. amount >= 0 and fee_bp >= 0, so truncation
# equals floor. No floating point is involved at any step.
sub fee_for {
    my ($amount, $fee_bp) = @_;
    use integer;
    return $amount * $fee_bp / 10000;
}

sub summarize {
    my ($days) = @_;
    my %s = (transactions => 0, amount => 0, fee => 0, payout => 0);
    for my $d (@$days) { $s{$_} += $d->{$_} for keys %s }
    return \%s;
}

sub statement_csv {
    my ($days) = @_;
    my @cols = qw(transactions amount fee payout);
    my $csv  = "date,settlement_date,transactions,amount,fee,payout\n";
    $csv .= join(',', $_->{date}, $_->{settlement_date}, @{$_}{@cols}) . "\n" for @$days;
    my $s = summarize($days);
    $csv .= join(',', 'TOTAL', '', @{$s}{@cols}) . "\n";
    return $csv;
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

sub cmd_build {
    # Builds are serialised: a slow cron run and a manual run must not
    # interleave writes or sweep each other's temporary files.
    open my $lock, '>', "$Bin/.build.lock" or die "cannot open build lock: $!\n";
    flock $lock, LOCK_EX or die "cannot lock build: $!\n";

    my $f = load_figures();
    my $counter = count_button_presses();
    my $built_at = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime);

    make_path("$OUT/api");
    write_file("$OUT/api/merchants.json", $JSON->encode([
        map { my $m = $_; +{ map { $_ => $m->{$_} } qw(merchant_id merchant_name agency_id agency_name distributor_id distributor_name) } } @{ $f->{merchants} }
    ]));
    write_file("$OUT/api/counter.json", $JSON->encode({ %$counter, counted_at => $built_at }));
    write_file("$OUT/api/periods.json", $JSON->encode({ periods => $f->{periods} }));
    write_file("$OUT/index.html", page_index($f));

    for my $m (@{ $f->{merchants} }) {
        my $mid = $m->{merchant_id};
        make_path("$OUT/m/$mid", "$OUT/api/m/$mid");
        write_file("$OUT/m/$mid/index.html", page_redirect(@{ $f->{periods} } ? "$f->{periods}[-1].html" : '../../'));
        for my $p (@{ $f->{periods} }) {
            my $days = $f->{daily}{$mid}{$p} // [];
            my $summary = summarize($days);
            make_path("$OUT/api/m/$mid/$p");
            write_file("$OUT/m/$mid/$p.csv", statement_csv($days));
            write_file("$OUT/api/m/$mid/$p/summary.json", $JSON->encode({ merchant_id => $mid, period => $p, %$summary }));
            write_file("$OUT/api/m/$mid/$p/daily.json", $JSON->encode($days));
            write_file("$OUT/m/$mid/$p.html", page_period($f, $m, $p, $days, $summary, $counter, $built_at));
        }
    }
    remove_stale_outputs();
    printf "built %d merchants x %d periods (button pressed %d times)\n",
        scalar @{ $f->{merchants} }, scalar @{ $f->{periods} }, $counter->{total};
}

# Every file this build writes is recorded by write_file; anything else left in
# out/ by an earlier build (a period or merchant that no longer exists) is
# removed so that it can no longer be served or counted.
my %WRITTEN;

sub remove_stale_outputs {
    my @stale;
    find({ no_chdir => 1, wanted => sub { push @stale, $_ if -f $_ && !$WRITTEN{$_} && !/\.tmp\.\d+\z/ } }, $OUT);
    unlink @stale;
}

# FR-4. A press is a GET of a statement CSV path that the server answered with
# 200, as recorded in the access log (Common Log Format). The only exception is
# a response the server failed to write (the socket refused it); that is
# logged as 499 and is not a press. Whether the client actually read the bytes
# is not considered: a client that closes politely before reading is still
# counted, because the server did answer. A request is only answered once its
# header block is complete (see handle_request). Later chapters reproduce this rule:
# "answered 200, and the answer was successfully written".
# Counting happens at build time, so the panel is at most one cron interval
# stale.
sub count_button_presses {
    my %c = (total => 0, by_merchant => {});
    open my $fh, '<', "$LOGS/access.log" or return \%c;
    while (my $line = <$fh>) {
        next unless $line =~ m{^\S+ \S+ \S+ \[[^\]]+\] "GET /m/(M\d{3})/\d{4}-\d{2}\.csv(?:\?\S*)? HTTP/1\.[01]" 200 };
        $c{total}++;
        $c{by_merchant}{$1}++;
    }
    return \%c;
}

# ---------------------------------------------------------------------------
# HTML. Server-side rendered, as was the custom.
# ---------------------------------------------------------------------------

my $STYLE = <<'CSS';
body { font-family: Georgia, "Times New Roman", serif; max-width: 860px; margin: 2em auto; padding: 0 1em; color: #111; background: #fdfcf8; }
h1 { font-size: 1.6em; margin-bottom: 0; }
.crumb { color: #666; margin-top: .2em; }
table { border-collapse: collapse; width: 100%; margin: 1em 0; }
th, td { border: 1px solid #999; padding: .3em .6em; }
th { background: #eee; text-align: left; }
td.n { text-align: right; font-family: "Courier New", monospace; }
nav a { margin-right: .8em; }
.button { display: inline-block; padding: .6em 1.2em; background: #003399; color: #fff; text-decoration: none; border: 2px outset #6699ff; font-weight: bold; }
.counter { border: 1px dashed #999; padding: .6em 1em; margin: 1em 0; background: #fffbe6; }
footer { color: #888; font-size: .85em; margin-top: 3em; }
CSS

sub html_doc {
    my ($title, $body) = @_;
    return <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${\ esc($title)}</title>
<style>
$STYLE</style>
</head>
<body>
$body<footer>Acme Payments merchant portal &middot; fictional data &middot; Chapter 0: one Perl script and a cron job.</footer>
</body>
</html>
HTML
}

sub page_index {
    my ($f) = @_;
    my $rows = join '', map {
        sprintf qq{<tr><td><a href="m/%s/">%s</a></td><td>%s</td><td>%s</td></tr>\n},
            esc($_->{merchant_id}), esc($_->{merchant_name}), esc($_->{agency_name}), esc($_->{distributor_name})
    } @{ $f->{merchants} };
    return html_doc('Acme Payments — Merchant Portal', <<"HTML");
<h1>Acme Payments — Merchant Portal</h1>
<p class="crumb">Select your merchant account.</p>
<table>
<tr><th>Merchant</th><th>Agency</th><th>Distributor</th></tr>
$rows</table>
HTML
}

sub page_redirect {
    my $target = esc($_[0]);
    return qq{<!DOCTYPE html>\n<meta charset="utf-8">\n<meta http-equiv="refresh" content="0; url=$target">\n<a href="$target">Continue</a>\n};
}

sub page_period {
    my ($f, $m, $period, $days, $s, $counter, $built_at) = @_;
    my $mid = $m->{merchant_id};
    # Identifiers come from generated data; escaped anyway, like everything else.
    my ($mid_html, $period_html) = (esc($mid), esc($period));
    my $nav = join '', map {
        my $p = esc($_);
        $_ eq $period ? "<strong>$p</strong> " : qq{<a href="$p.html">$p</a>}
    } @{ $f->{periods} };
    my $rows = join '', map {
        sprintf qq{<tr><td>%s</td><td>%s</td><td class="n">%s</td><td class="n">%s</td><td class="n">%s</td><td class="n">%s</td></tr>\n},
            esc($_->{date}), esc($_->{settlement_date}), map { commify($_) } @{$_}{qw(transactions amount fee payout)}
    } @$days;
    my $mine = $counter->{by_merchant}{$mid} // 0;
    return html_doc("$m->{merchant_name} — Settlement $period", <<"HTML");
<h1>${\ esc($m->{merchant_name})}</h1>
<p class="crumb">${\ esc($m->{distributor_name})} &rsaquo; ${\ esc($m->{agency_name})} &rsaquo; $mid_html &middot; fee rate ${\ bp_percent($m->{fee_bp})}%</p>
<nav>Period: $nav &middot; <a href="../../">all merchants</a></nav>

<h2>Settlement summary — $period_html</h2>
<table>
<tr><th>Transactions</th><th>Amount (KRW)</th><th>Fees (KRW)</th><th>Expected payout (KRW)</th></tr>
<tr><td class="n">${\ commify($s->{transactions})}</td><td class="n">${\ commify($s->{amount})}</td><td class="n">${\ commify($s->{fee})}</td><td class="n">${\ commify($s->{payout})}</td></tr>
</table>

<p><a class="button" href="$period_html.csv" download="acme-statement-$mid_html-$period_html.csv">Download settlement statement (CSV)</a></p>

<div class="counter">This button has been pressed <strong>${\ commify($mine)}</strong> times for this merchant,
<strong>${\ commify($counter->{total})}</strong> times in total. <small>(Counted from the access log at $built_at.)</small></div>

<h2>Daily breakdown</h2>
<table>
<tr><th>Date</th><th>Settles on</th><th>Transactions</th><th>Amount</th><th>Fees</th><th>Payout</th></tr>
$rows</table>
HTML
}

# ---------------------------------------------------------------------------
# serve — a small HTTP/1.0 server. One request at a time, as nature intended.
# ---------------------------------------------------------------------------

my %MIME = (
    html => 'text/html; charset=utf-8',
    csv  => 'text/csv; charset=utf-8',
    json => 'application/json; charset=utf-8',
);

sub cmd_serve {
    my (%opt) = @_;
    my $port = $opt{port} // 8097;
    make_path($LOGS);
    open my $log, '>>', "$LOGS/access.log" or die "cannot open access log: $!\n";
    $log->autoflush(1);

    # A client that disconnects mid-response must not take the server with it.
    $SIG{PIPE} = 'IGNORE';

    my $server = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 16, ReuseAddr => 1)
        or die "cannot listen on $port: $!\n";
    print "serving $OUT on http://127.0.0.1:$port/\n";

    while (1) {
        my $client = $server->accept;
        unless ($client) {
            next if $!{EINTR} || $!{ECONNABORTED};
            die "accept failed: $!\n";
        }
        my $peer = $client->peerhost // '-';
        my ($status, $bytes, $request) = handle_request($client);    # closes $client
        printf $log qq{%s - - [%s] "%s" %d %d\n},
            $peer, clf_time(), log_escape($request), $status, $bytes;
    }
}

# The server handles one connection at a time. A client that never finishes
# its request headers would block everyone else, so reading is capped at
# $READ_TIMEOUT seconds; such a client gets a 408 and is dropped.
my $READ_TIMEOUT = 5;
my $MAX_HEADER_BYTES = 8192;    # request line plus headers

# Common Log Format timestamp in UTC, with English month names regardless of
# locale (strftime's %b follows LC_TIME).
sub clf_time {
    my @t = gmtime;
    my @mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf '%02d/%s/%04d:%02d:%02d:%02d +0000', $t[3], $mon[ $t[4] ], $t[5] + 1900, $t[2], $t[1], $t[0];
}

sub handle_request {
    my ($client) = @_;
    # A request is only answered once its header block is complete (a blank
    # line ends it, CRLF or bare LF). A client that closes before that gets a
    # 400 and so can never produce a counted press.
    my $buf = '';
    my $complete = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $READ_TIMEOUT;
        while ($buf !~ /\r?\n\r?\n/ && length $buf <= $MAX_HEADER_BYTES) {
            my $n = sysread($client, $buf, 4096, length $buf);
            last unless $n;
        }
        alarm 0;
        1;
    };
    alarm 0;
    # The request line runs to the first LF, minus an optional CR before it.
    # It is parsed and logged in full; the 8 KB header cap already bounds it.
    my ($request) = $buf =~ /\A([^\n]*)/;
    $request //= '';
    $request =~ s/\r\z//;
    return respond($client, 408, 'text/plain', "request timeout\n", $request) unless $complete;
    return respond($client, 400, 'text/plain', "bad request\n", $request) if $request =~ /\r/;
    my ($head) = $buf =~ /\A(.*?\r?\n\r?\n)/s;
    return respond($client, 400, 'text/plain', "request too large\n", $request)
        if length($head // $buf) > $MAX_HEADER_BYTES;
    return respond($client, 400, 'text/plain', "incomplete request\n", $request) unless defined $head;

    my ($method, $target) = $request =~ m{^(\S+) (\S+) HTTP/1\.[01]$};
    return respond($client, 400, 'text/plain', "bad request\n", $request) unless $method;
    return respond($client, 405, 'text/plain', "GET only\n", $request) unless $method eq 'GET';

    (my $path = $target) =~ s/\?.*//;
    # Routing is an exact, case-sensitive allow-list checked BEFORE the
    # filesystem is touched. macOS filesystems are case-insensitive by default,
    # so relying on -f would serve /M/m001/2026-07.CSV as well; the allow-list
    # makes behaviour identical on every platform and guarantees that each
    # successful statement download has exactly one spelling in the log (FR-4).
    # It also excludes `..`, `//` and `/./` by construction.
    return respond($client, 301, 'text/plain', "moved\n", $request, Location => "$path/")
        if $path =~ m{\A/m/M\d{3}\z} && -d $OUT . $path;
    return respond($client, 404, 'text/plain', "not found\n", $request)
        unless $path =~ m{\A(?:
              /(?:index\.html)?
            | /m/M\d{3}/(?:index\.html|\d{4}-\d{2}\.(?:csv|html))?
            | /api/(?:merchants|counter|periods)\.json
            | /api/m/M\d{3}/\d{4}-\d{2}/(?:summary|daily)\.json
        )\z}x;
    $path .= 'index.html' if $path =~ m{/\z};
    my $file = $OUT . $path;
    return respond($client, 404, 'text/plain', "not found\n", $request) unless -f $file;

    my ($ext) = $file =~ /\.(\w+)\z/;
    my %extra;
    if (($ext // '') eq 'csv' && $path =~ m{^/m/(M\d{3})/(\d{4}-\d{2})\.csv\z}) {
        $extra{'Content-Disposition'} = qq{attachment; filename="acme-statement-$1-$2.csv"};
    }
    # The file can vanish between -f and the read (a concurrent build removing a
    # stale output); answer 404 rather than letting the server die.
    my $body = eval { read_file($file) };
    return respond($client, 404, 'text/plain', "not found\n", $request) unless defined $body;
    return respond($client, 200, $MIME{ $ext // '' } // 'application/octet-stream', $body, $request, %extra);
}

# Writes are not timed out. Every response is small enough (< 32 KB) to fit in
# the kernel's socket buffer, so a client that never reads cannot block the
# single-threaded server here.
sub respond {
    my ($client, $status, $type, $body, $request, %headers) = @_;
    my %reason = (200 => 'OK', 301 => 'Moved Permanently', 400 => 'Bad Request', 404 => 'Not Found',
                  405 => 'Method Not Allowed', 408 => 'Request Timeout');
    my $head = "HTTP/1.0 $status $reason{$status}\r\nContent-Type: $type\r\nContent-Length: " . length($body) . "\r\n";
    $head .= "$_: $headers{$_}\r\n" for sort keys %headers;
    my $delivered = print $client $head, "Connection: close\r\n\r\n", $body;
    $delivered = close($client) && $delivered;
    # If the OS refused the response (the client had already gone), log the
    # nginx-style 499 with 0 bytes so the FR-4 counter does not count it.
    return $delivered ? ($status, length $body, $request) : (499, 0, $request);
}

# ---------------------------------------------------------------------------
# golden / verify — the contract every later chapter must honour (README P-5)
#
# verify checks the golden files and the built statement CSVs. The API JSON and
# HTML (FR-5, FR-1/2 presentation) are derived from the same figures but are not
# compared byte-for-byte; later chapters are held to the summary and statements.
# ---------------------------------------------------------------------------

sub golden_lines {
    my $f = load_figures();
    my (@summary, @statements);
    for my $m (@{ $f->{merchants} }) {
        for my $p (@{ $f->{periods} }) {
            my $days = $f->{daily}{ $m->{merchant_id} }{$p} // [];
            my $s = summarize($days);
            push @summary, join("\t", $m->{merchant_id}, $p, @{$s}{qw(transactions amount fee payout)}) . "\n";
            push @statements, sha256_hex(statement_csv($days)) . "  m/$m->{merchant_id}/$p.csv\n";
        }
    }
    my @data = map { sha256_hex(read_file("$DATA/$_")) . "  data/$_\n" } qw(merchants.csv transactions.csv);
    return (
        'summary.tsv'       => join('', "merchant_id\tperiod\ttransactions\tamount\tfee\tpayout\n", @summary),
        'statements.sha256' => join('', @statements),
        'data.sha256'       => join('', @data),
    );
}

sub cmd_golden {
    my %files = golden_lines();
    make_path($GOLDEN);
    write_file("$GOLDEN/$_", $files{$_}) for sort keys %files;
    print "wrote golden figures: ", join(', ', sort keys %files), "\n";
}

sub cmd_verify {
    my %files = golden_lines();
    my $failed = 0;
    for my $name (sort keys %files) {
        my $expected = eval { read_file("$GOLDEN/$name") } // '';
        my $ok = $expected eq $files{$name};
        printf "%-18s %s\n", $name, $ok ? 'ok' : 'MISMATCH';
        $failed++ unless $ok;
    }
    for my $line (split /\n/, $files{'statements.sha256'}) {
        my ($hash, $rel) = $line =~ /^(\w+)  (\S+)$/;
        my $built = eval { read_file("$OUT/$rel") };
        next if defined $built && sha256_hex($built) eq $hash;
        print "built file differs or missing: out/$rel\n";
        $failed++;
    }
    my %expected = map { /  (\S+)$/ ? ($1 => 1) : () } split /\n/, $files{'statements.sha256'};
    for my $csv (sort { $a cmp $b } bsd_glob("$OUT/m/*/*.csv")) {
        (my $rel = $csv) =~ s{^\Q$OUT\E/}{};
        next if $expected{$rel};
        print "unexpected file in out/: $rel\n";
        $failed++;
    }
    die "verify failed ($failed)\n" if $failed;
    print "verify ok\n";
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

my %OPTIONS = (generate => ['seed'], serve => ['port']);

sub parse_options {
    my ($command, @args) = @_;
    my %allowed = map { $_ => 1 } @{ $OPTIONS{$command} // [] };
    my %opt;
    while (@args) {
        my $arg = shift @args;
        my ($name) = $arg =~ /^--(\w+)$/;
        die "unknown option $arg for $command\n" unless defined $name && $allowed{$name};
        die "missing value for $arg\n" unless @args;
        my $value = shift @args;
        die "$arg must be a positive integer\n" unless $value =~ /\A\d+\z/ && $value > 0;
        die "$arg must be at most 65535\n"      if $name eq 'port' && $value > 65535;
        die "$arg must be at most 2147483646\n" if $name eq 'seed' && $value > 2147483646;
        $opt{$name} = $value;
    }
    return %opt;
}

sub date_range {
    my ($from, $to) = @_;
    my @days;
    for (my $d = $from; $d le $to; $d = add_days($d, 1)) { push @days, $d }
    return @days;
}

sub add_days {
    my ($date, $n) = @_;
    my ($y, $m, $d) = $date =~ /^(\d{4})-(\d{2})-(\d{2})$/ or die "bad date $date\n";
    return strftime('%Y-%m-%d', gmtime(timegm(0, 0, 12, $d, $m - 1, $y) + $n * 86400));
}

# The request line is client-controlled. Escape quotes, backslashes and control
# characters so that a crafted request cannot forge a log line that the button
# counter would read as a successful download.
sub log_escape {
    my ($s) = @_;
    $s =~ s/([\x00-\x1f\x7f"\\])/sprintf('\\x%02x', ord $1)/ge;
    return $s;
}

# 330 -> "3.30". Integer formatting only.
sub bp_percent {
    my ($bp) = @_;
    use integer;
    return sprintf('%d.%02d', $bp / 100, $bp % 100);
}

sub commify {
    my ($n) = @_;
    1 while $n =~ s/^(-?\d+)(\d{3})/$1,$2/;
    return $n;
}

sub esc {
    my ($s) = @_;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    return scalar <$fh>;
}

# Write to a temporary file and rename it into place. The cron `build`
# rewrites out/ while the server is running; rename is atomic on the same
# filesystem, so a request never sees a truncated or half-written file.
sub write_file {
    my ($path, $content) = @_;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or die "cannot write $tmp: $!\n";
    print $fh $content;
    close $fh or die "cannot close $tmp: $!\n";
    rename $tmp, $path or die "cannot rename $tmp to $path: $!\n";
    $WRITTEN{$path} = 1;
}

# Our CSVs never contain commas or quotes inside fields, so a split suffices.
# (The merchant names were chosen with this in mind. That is the 1997 way.)
sub read_csv {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $! (run `generate` first)\n";
    chomp(my $header = <$fh>);
    my @cols = split /,/, $header;
    my @rows;
    while (my $line = <$fh>) {
        chomp $line;
        my %r;
        @r{@cols} = split /,/, $line, -1;
        push @rows, \%r;
    }
    return \@rows;
}

sub write_csv {
    my ($path, $cols, $rows) = @_;
    write_file($path, join('', join(',', @$cols) . "\n", map { join(',', @$_) . "\n" } @$rows));
}

# ---------------------------------------------------------------------------
# Main. Kept at the bottom so every file-scoped table above is initialised
# before a command runs.
# ---------------------------------------------------------------------------

my $command = shift @ARGV // '';
die "usage: perl button.pl <" . join('|', sort keys %COMMANDS) . "> [options]\n"
    unless $COMMANDS{$command};
$COMMANDS{$command}->(parse_options($command, @ARGV));
exit 0;
