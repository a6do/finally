# Market Data Interface — Design

The unified Python API for retrieving stock prices in FinAlly. One interface,
two implementations: the GBM simulator by default, the Massive API when
`MASSIVE_API_KEY` is set.

Companion documents: [MASSIVE_API.md](MASSIVE_API.md) for the provider details,
[MARKET_SIMULATOR.md](MARKET_SIMULATOR.md) for the simulator.

Status: most of this is implemented in `backend/app/market/`. Sections marked
**Gap** describe what is designed here but not yet built.

---

## 1. The shape of the thing

The obvious design is a `get_price(ticker)` function that callers await. It is
the wrong one. Prices arrive on the provider's schedule, not the caller's — the
simulator ticks every 500ms, Massive answers a poll every 15 seconds — and a
request-shaped API forces every caller to either block on the network or invent
its own cache.

So the data flow is one-way and the cache sits in the middle:

```
  ┌─────────────────────┐
  │  MarketDataSource   │   abstract; picked by the factory at startup
  │  (background task)  │
  └──────────┬──────────┘
             │ writes
             ▼
      ┌─────────────┐
      │ PriceCache  │   in-memory, thread-safe, single source of truth
      └──────┬──────┘
             │ reads
   ┌─────────┼─────────┬──────────────┐
   ▼         ▼         ▼              ▼
 SSE      portfolio   trade      LLM context
 stream   valuation   execution   builder
```

Producers never call consumers. Consumers never call producers. Everything
meets at the cache, and nothing downstream can tell which source is running.

That last property is the whole point of the abstraction. It is also what makes
the simulator a genuine development environment rather than a toy: the SSE
endpoint, the portfolio maths, and the trade path are exercised identically
whether prices come from GBM or from an exchange.

---

## 2. `PriceUpdate` — the unit of data

Immutable, frozen, and the only price type that crosses a module boundary.

```python
@dataclass(frozen=True, slots=True)
class PriceUpdate:
    ticker: str
    price: float
    previous_price: float
    session_open: float
    timestamp: float                # Unix seconds, always

    @property
    def change(self) -> float: ...           # price - previous_price
    @property
    def change_percent(self) -> float: ...   # vs session_open, for the UI
    @property
    def tick_percent(self) -> float: ...     # vs previous_price, for flashes
    @property
    def direction(self) -> str: ...          # "up" | "down" | "flat"

    def to_dict(self) -> dict: ...           # SSE / JSON payload
```

Two decisions worth stating.

**Timestamps are Unix seconds, everywhere, converted at the boundary.** Massive
returns nanoseconds on trade fields and milliseconds on bar fields
(MASSIVE_API.md section 3.1); the simulator has no natural timestamp at all.
Both normalise before touching the cache, so nothing downstream ever asks what
unit it is holding.

**Gap: `session_open` and the two percentages.** The shipped `PriceUpdate` has
neither. PLAN.md sections 6 and 10 require a session-open baseline streamed in
every event so the UI can render `Chg %` against a fixed reference. Today the
frontend would receive only tick-over-tick change, which is near zero on every
update and useless as a column.

The distinction is not cosmetic. `change_percent` is measured against
`session_open` and answers "how has this moved today"; `tick_percent` is
measured against `previous_price` and drives the green/red flash. They are
different numbers with different consumers, and collapsing them into one field
is how the change column ends up permanently reading 0.00%.

---

## 3. `PriceCache` — the meeting point

```python
class PriceCache:
    def update(self, ticker: str, price: float,
               timestamp: float | None = None) -> PriceUpdate: ...
    def get(self, ticker: str) -> PriceUpdate | None: ...
    def get_price(self, ticker: str) -> float | None: ...
    def get_all(self) -> dict[str, PriceUpdate]: ...
    def remove(self, ticker: str) -> None: ...

    @property
    def version(self) -> int: ...    # monotonic; bumped on every update
```

**Thread-safe by a plain `Lock`, deliberately.** The simulator writes from an
asyncio task on the event loop; the Massive poller writes from a worker thread
via `asyncio.to_thread`; FastAPI route handlers defined with `def` read from
the threadpool. Three different execution contexts touch this object, so an
`asyncio.Lock` would not be enough. The critical sections are a dict lookup and
a dict assignment, so contention is not a concern worth optimising.

**`version` is how SSE detects change without diffing.** The stream loop wakes
every 500ms, compares `cache.version` against the value it last sent, and emits
only if it moved. This is what makes the stream change-driven rather than
fixed-cadence (PLAN.md section 6): under Massive on a slow poll the version sits
still and no events are emitted, and the keepalive comment covers the silence.

**Session open is recorded on first sight and never updated.** Inside `update`:

```python
prev = self._prices.get(ticker)
previous_price = prev.price if prev else price
session_open = prev.session_open if prev else price   # set once, ever
```

Set once per ticker per process. It resets when the backend restarts, which is
exactly what "session" means here and exactly what the column claims to
measure. It survives a *page* reload, which is the case that actually matters.

**`remove` clears the session open too**, since it drops the whole entry. A
ticker removed from the watchlist and re-added starts a new session baseline.
That is the correct behaviour and worth a test, because the alternative — a
stale baseline from an hour ago — produces a change percentage nobody can
explain.

---

## 4. `MarketDataSource` — the interface

```python
class MarketDataSource(ABC):
    @abstractmethod
    async def start(self, tickers: list[str]) -> None: ...
    @abstractmethod
    async def stop(self) -> None: ...
    @abstractmethod
    async def add_ticker(self, ticker: str) -> None: ...
    @abstractmethod
    async def remove_ticker(self, ticker: str) -> None: ...
    @abstractmethod
    def get_tickers(self) -> list[str]: ...

    @property
    @abstractmethod
    def status(self) -> SourceStatus: ...      # Gap; see section 6
```

Contract, binding on both implementations:

- `start` is called once, spawns a background task, and returns promptly. It
  seeds the cache before returning, so the first SSE client to connect has data
  rather than an empty grid.
- `stop` is idempotent and cancels the task. After it returns, nothing writes
  to the cache.
- `add_ticker` / `remove_ticker` are no-ops when redundant. `add_ticker` makes a
  price available promptly — immediately for the simulator, on the next poll for
  Massive.
- `remove_ticker` also evicts from the cache. The source owns that entry's
  lifetime.
- **The background task never dies.** A failed tick or poll is logged and the
  loop continues. A task that exits leaves the app looking connected and frozen,
  which is worse than any single bad tick.

The ticker set is the **watchlist union non-zero positions** (PLAN.md section
6). The caller computes that; the source is handed a list and does not know why
those tickers. That keeps portfolio concerns out of the market layer.

---

## 5. The factory

```python
def create_market_data_source(cache: PriceCache) -> MarketDataSource:
    """Simulator unless MASSIVE_API_KEY is set and non-empty."""
```

The whole selection rule is: key present and non-empty → Massive; otherwise
simulator. Read once at startup, never re-read. `.strip()` matters, because a
`.env` line of `MASSIVE_API_KEY=` followed by a stray space is otherwise a
truthy key that produces 401s.

**Gap: capability probe and fallback.** The current factory returns a
`MassiveDataSource` on the strength of a non-empty string, and if the key is
invalid or free-tier the app streams nothing. Given MASSIVE_API.md section 2 —
snapshots are unavailable on the free tier — this is the likely outcome for a
user who signs up for a key to try the feature.

The factory should ask the API what the key can do, once, at startup:

```python
async def create_market_data_source(cache: PriceCache) -> MarketDataSource:
    api_key = os.environ.get("MASSIVE_API_KEY", "").strip()
    if not api_key:
        return SimulatorDataSource(cache)

    mode = await probe_massive(api_key)      # one snapshot call for one ticker
    match mode:
        case Mode.LIVE:
            return MassiveDataSource(api_key, cache, poll_interval=15.0)
        case Mode.EOD:
            logger.warning(
                "Massive key has no snapshot access (free tier). Using "
                "end-of-day closes; prices will not move."
            )
            return MassiveEODSource(api_key, cache, poll_interval=60.0)
        case Mode.UNUSABLE:
            logger.error("Massive key rejected. Falling back to the simulator.")
            return SimulatorDataSource(cache)
```

`probe_massive` is one snapshot request for a single ticker: `200` means live,
`403` means free tier, `401` means a bad key. It costs one request and it turns
three silent failure modes into one log line and a working app.

The fallback to the simulator on a bad key is a deliberate choice about what a
demo application owes its user. A hard startup failure is defensible in a
service where wrong data is dangerous; here the alternative to real prices is
simulated prices, and a working terminal with a warning in the log beats a
broken one.

---

## 6. Reporting status honestly

**Gap.** The connection dot in the header reflects the SSE connection only. It
is green whenever the browser holds the stream open, which is true even when
the backend is failing every poll or serving yesterday's closes.

PLAN.md section 10 treats the motionless-grid problem as documentation ("do not
treat a motionless grid as a dropped connection"). Documentation does not reach
the person looking at the screen. The source should report what it is actually
doing, and the header should show it:

```python
@dataclass(frozen=True)
class SourceStatus:
    kind: str                  # "simulator" | "massive-live" | "massive-eod"
    healthy: bool              # last cycle succeeded
    market_open: bool | None   # None when unknown or not applicable
    last_update: float | None  # Unix seconds
    detail: str | None         # e.g. "rate limited, backing off"
```

Exposed at `GET /api/market/status` and rendered as a short label beside the
dot: `SIMULATED`, `LIVE`, `DELAYED 15M`, `EOD - MARKET CLOSED`. Massive's
`/v1/marketstatus/now` is free on every plan and real-time (MASSIVE_API.md
section 3.3), so `market_open` is cheap to fill in accurately.

This is a small amount of work that removes the single most confusing thing a
user of the Massive path can encounter.

---

## 7. Implementation notes per source

### Simulator

Detailed in [MARKET_SIMULATOR.md](MARKET_SIMULATOR.md). From the interface's
point of view: an asyncio task, a 500ms `step()`, prices written straight to
the cache. No I/O, no failure modes worth handling beyond logging.

### Massive (live)

One `get_snapshot_all` per poll covering every tracked ticker, so the request
budget is independent of watchlist size.

The client is **synchronous** — there is no async client in `massive` 2.2.0
(MASSIVE_API.md section 4) — so every call goes through `asyncio.to_thread`.
Calling it directly on the event loop stalls the SSE stream for every connected
client for the duration of the HTTP request.

Price extraction falls back through last trade, minute bar, day close, previous
close, because which fields are present depends on plan and time of day. The
shipped implementation reads `snap.last_trade.timestamp`, which does not exist
on the real model, and divides nanoseconds by 1000; both are documented in
MASSIVE_API.md section 5 and both must be fixed before this path can work at
all.

Error handling distinguishes permanent from transient:

```python
except AuthError:            # 401/403 - retrying cannot help
    self._status = SourceStatus(kind=..., healthy=False,
                                detail="key rejected or plan lacks access")
    return                   # stop polling; do not hammer
except BadResponse as e:     # 429, 5xx - transient
    self._backoff()          # next poll waits longer
```

A 403 retried every 15 seconds forever is not resilience. It is a loop that
produces nothing and hides the reason.

### Massive (end-of-day)

**Gap.** Not implemented. One `get_grouped_daily_aggs` call per poll returns
every US ticker's daily bar; filter to the tracked set and write closes to the
cache. Poll infrequently — once a minute is generous for data that changes once
a day — and walk the date backwards over weekends and holidays, which return an
empty result set.

Prices genuinely do not move in this mode. The status must say so; the grid
sitting still is then correct and explained rather than alarming.

---

## 8. Usage

```python
from app.market import PriceCache, create_market_data_source

# Startup (FastAPI lifespan)
cache = PriceCache()
source = await create_market_data_source(cache)
await source.start(tracked_tickers())      # watchlist | non-zero positions

# Reads - synchronous, in-memory, safe from any context
update = cache.get("AAPL")
price = cache.get_price("AAPL")
prices = cache.get_all()

# Watchlist changes
await source.add_ticker("TSLA")
await source.remove_ticker("GOOGL")        # only if no position is held

# Shutdown
await source.stop()
```

Trade execution and portfolio valuation read `cache.get_price` and nothing
else. Neither imports a source class; neither knows a provider exists.

---

## 9. Testing

Per PLAN.md section 12, plus what this design adds:

- **Conformance, run against both implementations.** A shared test class
  parametrised over the two sources: `start` seeds the cache; `stop` is
  idempotent; `add_ticker` makes a price available; `remove_ticker` evicts it;
  the background task survives an induced failure.
- **Session open.** Recorded on first update, unchanged by later updates,
  cleared by `remove`, and present on every serialised event.
- **Timestamp normalisation.** Nanosecond trade timestamps and millisecond bar
  timestamps both arrive in the cache as plausible Unix seconds.
- **Massive fixtures built from real payloads.** Parse the documented sample
  JSON through `TickerSnapshot.from_dict` rather than hand-rolling `MagicMock`
  objects. The existing suite mocks `last_trade.timestamp` into existence and
  therefore tests a field the library does not have — the bug and the test agree
  with each other (MASSIVE_API.md section 5).
- **Error classification.** 401/403 stops polling and marks the source
  unhealthy; 429/5xx backs off and recovers.
- **Factory probe.** Live key, free-tier key, and bad key each select the right
  source.

---

## 10. Summary of gaps

| Gap | Where | Why it matters |
|---|---|---|
| `session_open` absent from `PriceUpdate` / `PriceCache` | sections 2, 3 | The UI's `Chg %` column has no baseline and reads ~0.00% forever |
| `change_percent` measured against the previous tick | section 2 | Wrong denominator for the column it feeds |
| No capability probe in the factory | section 5 | A free-tier key yields an empty grid and a green dot |
| No EOD source | section 7 | The free tier has no working path at all |
| No `SourceStatus` / status endpoint | section 6 | The user cannot tell simulated from live from stale |
| `last_trade.timestamp` and the ns/ms conversion | section 7 | The Massive path cannot populate the cache |
| `massive>=1.0.0` in `pyproject.toml` | MASSIVE_API.md section 4 | Permits a 1.x resolve predating `api.massive.com` |
