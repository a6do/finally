# Massive API — Reference for FinAlly

Research notes on the Massive market data API, scoped to what FinAlly needs:
live and end-of-day prices for a handful of US large-cap tickers.

Everything here was verified on 2026-08-11 against the live docs
(`https://massive.com/docs/llms.txt`) and against `massive` version **2.2.0**
as installed in `backend/.venv`. Where the shipped code disagrees with the
library, that is called out rather than smoothed over.

---

## 1. The rebrand

Polygon.io became **Massive** on 30 October 2025. For our purposes:

| Thing | Before | Now |
|---|---|---|
| Docs | `polygon.io/docs` | `massive.com/docs` |
| API base | `api.polygon.io` | `api.massive.com` (default in SDK 2.x) |
| PyPI package | `polygon-api-client` | `massive` |
| Import | `from polygon import RESTClient` | `from massive import RESTClient` |
| API keys | — | unchanged; existing keys keep working |

`api.polygon.io` still resolves and `polygon.io/*` 301s to `massive.com/*`, but
the endpoint *paths* never changed — they are still `/v2/...` and `/v3/...`.
The rebrand renamed the host and the package, nothing else.

The docs site publishes a machine-readable index at
`https://massive.com/docs/llms.txt`, and every page has a `.md` twin (append
`.md` to any docs URL). That is the fastest way to re-check any of this later.

---

## 2. The constraint that shapes everything: plan access

This is the single most important finding, and it is not obvious from the
marketing pages. **The snapshot endpoints are not available on the free tier.**

Verified plan access for the endpoints that could serve prices:

| Endpoint | Path | Basic (free) | Starter | Advanced |
|---|---|---|---|---|
| Full Market Snapshot | `/v2/snapshot/locale/us/markets/stocks/tickers` | **Not included** | 15-min delayed | Real-time |
| Single Ticker Snapshot | `/v2/snapshot/.../tickers/{ticker}` | **Not included** | 15-min delayed | Real-time |
| Unified Snapshot | `/v3/snapshot` | **Not included** | 15-min delayed | Real-time |
| Last Trade | `/v2/last/trade/{ticker}` | **Not included** | **Not included** | Real-time |
| Daily Market Summary (grouped) | `/v2/aggs/grouped/locale/us/market/stocks/{date}` | Included (EOD) | 15-min delayed | Real-time |
| Previous Day Bar | `/v2/aggs/ticker/{ticker}/prev` | Included (EOD) | 15-min delayed | Real-time |
| Custom Bars | `/v2/aggs/ticker/{t}/range/{mult}/{span}/{from}/{to}` | Included (EOD) | 15-min delayed | Real-time |
| Market Status | `/v1/marketstatus/now` | Included, real-time | real-time | real-time |

Rate limit: **5 requests/minute on Basic**; paid plans are effectively
unlimited, with a documented recommendation to stay under 100 req/sec.

### What this means for FinAlly

A user who signs up for a free key and sets `MASSIVE_API_KEY` gets **403 on
every snapshot call**. The app would show an empty grid with a green connection
dot — the worst failure mode we have, because it looks like a bug in our code.

So the Massive path needs two modes, chosen by what the key can actually do:

- **Live mode** (Starter and above) — poll the Full Market Snapshot. One
  request returns every watched ticker.
- **End-of-day mode** (Basic/free) — one call to the grouped daily aggregate
  gives the last close for *every* US ticker. Prices are static; the grid does
  not move, and the UI must say so rather than implying a live feed.

Both are one request per poll regardless of how many tickers are watched, which
is what makes the 5/min limit survivable.

---

## 3. Endpoints in detail

### 3.1 Full Market Snapshot — the live path

`GET /v2/snapshot/locale/us/markets/stocks/tickers`

The workhorse. Pass a comma-separated `tickers` list and get one object back
per ticker, each carrying the last trade, last quote, the current day bar, the
most recent minute bar, and the previous day's bar.

Query parameters:

| Parameter | Type | Notes |
|---|---|---|
| `tickers` | array | Case-sensitive, comma-separated. **An empty value returns all 10,000+ tickers** — always pass an explicit list |
| `include_otc` | boolean | Default false. Leave it false |

Response (trimmed to what we use):

```json
{
  "status": "OK",
  "count": 1,
  "tickers": [
    {
      "ticker": "BCAT",
      "todaysChange": -0.124,
      "todaysChangePerc": -0.601,
      "updated": 1605192894630916600,
      "lastTrade": { "p": 20.506, "s": 2416, "t": 1605192894630916600, "x": 4 },
      "day":     { "o": 20.64, "h": 20.64, "l": 20.506, "c": 20.506, "v": 37216 },
      "prevDay": { "o": 20.79, "h": 21.0,  "l": 20.5,   "c": 20.63,  "v": 292738 },
      "min":     { "o": 20.506, "c": 20.506, "t": 1684428600000, "v": 5000 }
    }
  ]
}
```

Two traps in that payload:

**Timestamp units are not uniform.** `lastTrade.t` and `updated` are **Unix
nanoseconds**. `min.t` is **Unix milliseconds**. Dividing the wrong one by 1000
gives a timestamp roughly 50,000 years in the future. Divide `lastTrade.t` by
`1e9`.

**Fields are plan-gated and can be absent.** `lastTrade` is only returned if
the plan includes trades; `lastQuote` only if it includes quotes. On a Starter
key you may get `day` and `prevDay` but no `lastTrade` at all. Price extraction
must fall back rather than assume.

Snapshot data is cleared daily at 3:30 AM ET and repopulates from about
4:00 AM ET. Between those times, `day` is empty and `prevDay` is the only
usable price.

### 3.2 Daily Market Summary (grouped daily) — the free-tier path

`GET /v2/aggs/grouped/locale/us/market/stocks/{date}`

One request, every US ticker, one daily bar each. `date` is `YYYY-MM-DD` and
must be a trading day — a weekend or holiday returns `resultsCount: 0`.

```json
{
  "status": "OK",
  "adjusted": true,
  "resultsCount": 3,
  "results": [
    { "T": "VSAT", "o": 34.9, "h": 35.47, "l": 34.21, "c": 34.24,
      "v": 312583, "vw": 34.4736, "n": 4966, "t": 1602705600000 }
  ]
}
```

`T` is the ticker, `c` the close, `t` is **milliseconds** here. Filter the
result list down to our allowlist client-side; the endpoint has no ticker
filter.

### 3.3 Market Status — free, real-time, and worth using

`GET /v1/marketstatus/now`

Included on every plan and updated in real time. Returns
`{"market": "open" | "closed" | "extended-hours", "earlyHours": bool,
"afterHours": bool, "exchanges": {...}, "serverTime": "..."}`.

PLAN.md section 10 flags the "motionless grid outside market hours" problem and
resolves it as documentation. This endpoint lets us do better: ask the API
whether the market is open and tell the user, instead of leaving them to guess
whether the app is broken. It costs one request per poll cycle, which matters
on a 5/min budget — call it once a minute at most, or once per poll in live
mode where the limit is not binding.

### 3.4 Custom Bars — historical backfill

`GET /v2/aggs/ticker/{ticker}/range/{multiplier}/{timespan}/{from}/{to}`

Included on all plans. Not needed for the core build — sparklines accumulate
from the SSE stream on the frontend — but this is the endpoint to use if we
ever want charts that are populated at page load instead of filling in
progressively. It is one request per ticker, so it does not fit the free tier's
budget for anything but a one-off.

---

## 4. The Python client

```bash
uv add massive
```

Installed and verified: **2.2.0**. `backend/pyproject.toml` currently pins
`massive>=1.0.0`, which would permit a 1.x resolve; it should be `>=2.0.0`,
since 1.x predates the `api.massive.com` default.

### Client construction

```python
from massive import RESTClient

client = RESTClient(
    api_key=api_key,          # or the MASSIVE_API_KEY env var
    base="https://api.massive.com",   # default in 2.x
    connect_timeout=10.0,
    read_timeout=10.0,
    retries=3,                # built-in urllib3 retry
    trace=False,              # True prints full request/response
)
```

Verified signature defaults: `connect_timeout=10.0`, `read_timeout=10.0`,
`retries=3`, `base="https://api.massive.com"`, `pagination=True`.

**The client is synchronous.** There is no `AsyncRESTClient` in 2.2.0 — the
top-level exports are `RESTClient`, `WebSocketClient`, `AuthError`,
`BadResponse`. Every call from our async backend must go through
`asyncio.to_thread`, or it blocks the event loop and stalls the SSE stream for
every connected client.

### Methods we care about

| Purpose | Method |
|---|---|
| Full market snapshot | `get_snapshot_all(market_type, tickers=None, include_otc=False)` |
| Single ticker snapshot | `get_snapshot_ticker(market_type, ticker)` |
| Grouped daily (EOD, all tickers) | `get_grouped_daily_aggs(date, adjusted=None, locale="us", market_type="stocks")` |
| Previous close | `get_previous_close_agg(ticker, adjusted=None)` |
| Custom bars | `list_aggs(ticker, multiplier, timespan, from_, to, limit=None)` |
| Unified snapshot | `list_universal_snapshots(type=..., ticker_any_of=[...])` |

### Live prices for many tickers

```python
from massive import RESTClient
from massive.rest.models import SnapshotMarketType

client = RESTClient(api_key=api_key)

snapshots = client.get_snapshot_all(
    market_type=SnapshotMarketType.STOCKS,
    tickers=["AAPL", "GOOGL", "MSFT"],
)

for snap in snapshots:
    print(snap.ticker, snap.last_trade.price, snap.todays_change_percent)
```

The SDK converts the JSON's terse keys into readable attribute names. The
mapping is not one-to-one with the JSON, which is where the shipped code went
wrong — see section 5.

`TickerSnapshot` fields (verified via `dataclasses.fields`):

```
ticker, day, min, prev_day, last_trade, last_quote,
todays_change, todays_change_percent, updated, fair_market_value
```

`snapshot.LastTrade` fields:

```
ticker, trf_timestamp, sequence_number, sip_timestamp, participant_timestamp,
conditions, correction, id, price, trf_id, size, exchange, tape
```

Note what is **not** there: no field named `timestamp`. The JSON `t` maps to
`sip_timestamp`.

`Agg` (used for `day`, `prev_day`) and `GroupedDailyAgg`:

```
Agg:             open, high, low, close, volume, vwap, timestamp, transactions, otc
GroupedDailyAgg: ticker, open, high, low, close, volume, vwap, timestamp,
                 transactions, otc
```

### End-of-day prices for many tickers

```python
from datetime import date, timedelta

def most_recent_weekday(today: date) -> date:
    """Last Mon-Fri on or before today. Does not know about holidays."""
    d = today
    while d.weekday() >= 5:       # 5=Sat, 6=Sun
        d -= timedelta(days=1)
    return d

def fetch_eod(client, tickers: set[str], as_of: date) -> dict[str, float]:
    """Closing price per ticker. One request for the whole market."""
    bars = client.get_grouped_daily_aggs(date=as_of.isoformat(), adjusted=True)
    wanted = {t.upper() for t in tickers}
    return {b.ticker: b.close for b in bars if b.ticker in wanted}
```

Because a holiday returns an empty list, production code should walk back a day
at a time — bounded, say four attempts — until it gets results.

### Market status

```python
status = client.get_market_status()
is_open = status.market == "open"
```

### Errors

Two exception types, `AuthError` and `BadResponse`. The wire format for a
failure, confirmed by an unauthenticated call:

```
$ curl "https://api.massive.com/v2/snapshot/locale/us/markets/stocks/tickers?tickers=AAPL"
{"status":"ERROR","request_id":"69e4...","error":"API Key was not provided"}
HTTP 401
```

Status codes to expect and what each means for us:

| Code | Cause | Right response |
|---|---|---|
| 401 | Missing or invalid key | Fatal and permanent. Log loudly, fall back to the simulator |
| 403 | Key valid, plan does not include this endpoint | Not retryable. Switch to the EOD path |
| 429 | Over 5 req/min on Basic | Back off; the poll interval was too aggressive |
| 5xx | Massive-side | Transient; the next poll retries |

The distinction between 401/403 and 429/5xx is the one that matters. A 403 will
never succeed no matter how many times it is retried, so retrying it silently
in a loop is how you get an app that looks connected and shows nothing.

### WebSockets

`massive.WebSocketClient` exists and would give true push updates instead of
polling. We are not using it: real-time WebSocket access is an Advanced-plan
feature, it needs its own reconnect and auth lifecycle, and PLAN.md section 6
already committed to REST polling on the grounds that it works on all tiers.
Noted here so the choice is on the record rather than an oversight.

---

## 5. Two defects in the shipped client

`backend/app/market/massive_client.py` has never run against a real API key.
Two things break the moment it does.

### 5.1 `last_trade.timestamp` does not exist

Line 106 reads:

```python
timestamp = snap.last_trade.timestamp / 1000.0
```

`snapshot.LastTrade` has no `timestamp` attribute — the field is
`sip_timestamp`. This raises `AttributeError`, which the enclosing
`except (AttributeError, TypeError)` catches and turns into a per-ticker
warning. The result is not a crash: it is **every ticker silently skipped, an
empty cache, and a cheerful green connection dot**.

Verified by parsing the documented sample payload through the real model:

```python
>>> ts = TickerSnapshot.from_dict(sample)
>>> hasattr(ts.last_trade, "timestamp")
False
>>> ts.last_trade.sip_timestamp
1605192894630916600
```

### 5.2 The unit conversion is wrong by a factor of a million

Even with the right attribute, `/ 1000.0` is wrong. `sip_timestamp` is
**nanoseconds**; the correct divisor is `1e9`. The existing test asserts the
millisecond behaviour and passes, because it feeds in a millisecond value of
its own invention.

### Why the tests did not catch either

`backend/tests/market/test_massive.py` builds snapshots with `MagicMock()`:

```python
snap = MagicMock()
snap.last_trade = MagicMock()
snap.last_trade.price = price
snap.last_trade.timestamp = timestamp_ms
```

A `MagicMock` grows whatever attribute you ask it for. The test asserts that
the code reads `.timestamp` — a field the real library does not have — so the
test and the bug agree with each other and both are wrong. The fix is to build
fixtures with `TickerSnapshot.from_dict()` on captured JSON, so the real
model's field names are what the test binds to.

### The corrected extraction

```python
def extract_price(snap) -> tuple[float, float] | None:
    """(price, unix_seconds) from a snapshot, or None if it carries no price.

    Falls back through last trade, minute bar, day close, previous close,
    because which of these is present depends on the plan and time of day.
    """
    lt = snap.last_trade
    if lt is not None and lt.price:
        ts = (lt.sip_timestamp or lt.participant_timestamp)
        return lt.price, (ts / 1e9 if ts else time.time())

    if snap.min is not None and snap.min.close:
        # min.timestamp is milliseconds, unlike the trade timestamps
        return snap.min.close, (snap.min.timestamp or 0) / 1e3 or time.time()

    for bar in (snap.day, snap.prev_day):
        if bar is not None and bar.close:
            return bar.close, time.time()

    return None
```

---

## 6. Poll intervals

One snapshot request covers every watched ticker, so the interval depends only
on the plan's rate limit, not on watchlist size.

| Plan | Limit | Interval | Notes |
|---|---|---|---|
| Basic (free) | 5/min | 60s, EOD endpoint | Prices are yesterday's closes and do not move |
| Starter | unlimited | 15s | 15-minute delayed data; polling faster gains nothing |
| Developer | unlimited | 5s | 15-minute delayed |
| Advanced | unlimited | 2-5s | Genuinely real-time |

The plan's current default of 15s is right for Starter and above. On Basic it
is both useless and over the rate limit once market status is also being
polled.

---

## 7. Getting a key

Sign up at `https://massive.com/dashboard/signup`; keys are at
`https://massive.com/dashboard/keys`. Put it in `MASSIVE_API_KEY` in `.env` —
never in source, and never pasted into a chat with an agent.

The honest recommendation for this project stands: **leave it unset.** The
simulator produces a livelier, more demo-friendly terminal than a free Massive
key, which can only ever show static end-of-day closes.

---

## Sources

- [Massive API docs index (llms.txt)](https://massive.com/docs/llms.txt)
- [Stocks REST overview](https://massive.com/docs/rest/stocks/overview)
- [Full Market Snapshot](https://massive.com/docs/rest/stocks/snapshots/full-market-snapshot)
- [Daily Market Summary (grouped daily)](https://massive.com/docs/rest/stocks/aggregates/daily-market-summary)
- [Previous Day Bar](https://massive.com/docs/rest/stocks/aggregates/previous-day-bar)
- [Last Trade](https://massive.com/docs/rest/stocks/trades-quotes/last-trade)
- [Market Status](https://massive.com/docs/rest/stocks/market-operations/market-status)
- [Unified Snapshot](https://massive.com/docs/rest/stocks/snapshots/unified-snapshot)
- [Request limits](https://massive.com/knowledge-base/article/what-is-the-request-limit-for-polygons-restful-apis)
- [massive-com/client-python](https://github.com/massive-com/client-python)
- [Polygon.io is now Massive](https://massive.com/blog/polygon-is-now-massive)
