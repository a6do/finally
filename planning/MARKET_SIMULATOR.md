# Market Simulator — Approach and Structure

How FinAlly generates plausible stock prices with no API key and no network.
The simulator is the default source (PLAN.md section 6) and therefore the one
almost every user and every E2E test will actually see.

Companion documents: [MARKET_INTERFACE.md](MARKET_INTERFACE.md) for the
interface it implements, [MASSIVE_API.md](MASSIVE_API.md) for the real-data
alternative.

Status: implemented in `backend/app/market/simulator.py` and
`seed_prices.py`. The measurements in section 5 were taken from the shipped
code on 2026-08-11 and identify one calibration problem worth fixing.

---

## 1. What the simulator is for

Not forecasting, and not a backtest. The job is narrower: produce a price
stream that **looks right on screen and behaves correctly in the system**.

That splits into four requirements, and they pull against each other:

1. **Every tick should be visible.** A price that rounds to the same two
   decimals for seconds at a time means no flash animation and a dead-looking
   terminal.
2. **Movement over minutes should be plausible.** A stock that moves 8% in a
   two-minute demo is obviously fake.
3. **Tickers should move together.** Real markets have sector structure; ten
   independent random walks look like ten unrelated things, not a market.
4. **Something should occasionally happen.** A pure random walk is visually
   monotonous.

Geometric Brownian motion handles 1-3 from a single parameter set. Requirement
4 is bolted on as a separate shock process, and section 5 shows the bolt is
currently too tight.

---

## 2. The model

Standard GBM, discretised:

```
S(t+dt) = S(t) * exp( (mu - sigma^2/2) * dt  +  sigma * sqrt(dt) * Z )
```

| Term | Meaning |
|---|---|
| `S` | price |
| `mu` | annualised drift (expected return) |
| `sigma` | annualised volatility |
| `dt` | time step, as a fraction of a trading year |
| `Z` | standard normal draw, correlated across tickers |

Two properties earn GBM its place here. Prices cannot go negative, because the
process is multiplicative — no guard code, no clamping, no `max(price, 0.01)`
lurking in the tick loop. And volatility is proportional to price, so a $800
NVDA moves in larger dollar amounts than a $190 AAPL without any per-ticker
special-casing.

The `- sigma^2/2` correction makes `mu` the expected *log* return, so the
annualised drift means what a finance-literate reader expects. It is
numerically irrelevant at this `dt` and kept for correctness rather than effect.

### Choosing `dt`

Time is measured in trading years, so the annualised `mu` and `sigma` from
`seed_prices.py` can be quoted in their conventional units:

```python
TRADING_SECONDS_PER_YEAR = 252 * 6.5 * 3600   # 5,896,800
DEFAULT_DT = 0.5 / TRADING_SECONDS_PER_YEAR   # 8.4792e-08 for a 500ms tick
```

252 trading days of 6.5 hours. The simulator runs continuously rather than
only during market hours, so one wall-clock hour of a running app advances the
same distance as one market hour. Nobody watching notices; it keeps the
parameters interpretable.

---

## 3. Correlation

Independent draws per ticker would give ten unrelated walks. Real tickers move
together, so the draws are correlated through a Cholesky factor.

Build a correlation matrix `C` from sector rules, factor it as `C = L·Lᵀ`, and
transform independent normals into correlated ones:

```python
z_independent = np.random.standard_normal(n)
z_correlated  = self._cholesky @ z_independent      # L @ z
```

If `z` has identity covariance then `L·z` has covariance `L·Lᵀ = C`. That is
the whole trick: one matrix multiply per tick and the grid moves in sympathy.

Current structure (`seed_prices.py`):

| Pair | rho |
|---|---|
| Tech and tech | 0.6 |
| Finance and finance | 0.5 |
| Anything with TSLA | 0.3 |
| Cross-sector, or unknown | 0.3 |

TSLA is carved out of tech deliberately — it is the ticker a viewer is most
likely to be watching for independent drama, and pinning it at 0.6 to the rest
of tech wastes that.

### The constraint on rho values

A correlation matrix must be positive definite or `np.linalg.cholesky` raises
`LinAlgError` and the simulator fails to start. Block structures like this one
are safe under two rules, both verified numerically:

| Configuration | Min eigenvalue | Cholesky |
|---|---|---|
| 40 tickers, 3 groups, intra 0.6, cross 0.3 | +0.400 | OK |
| cross (0.7) > intra (0.6) | -1.109 | **Fails** |
| intra = 1.0 | -0.000 | **Fails** |

So: **every intra-group correlation must exceed the cross-group value, and none
may reach 1.0.** The block layout is otherwise well-conditioned and scales to
40 tickers and more groups without trouble. This belongs in a unit test that
asserts `np.linalg.eigvalsh(C).min() > 0` over the full allowlist, because the
failure mode is a backend that will not start and an error message that does
not mention correlation.

Rebuilding costs O(n²) to fill plus O(n³) to factor, on every add and remove.
At n=40 that is microseconds and not worth caching.

---

## 4. Structure

```
backend/app/market/
├── seed_prices.py    # data only: seed prices, per-ticker mu/sigma, groups
├── simulator.py      # GBMSimulator (pure maths) + SimulatorDataSource (async)
└── interface.py      # the ABC both sources implement
```

The split inside `simulator.py` is the important one.

**`GBMSimulator`** is synchronous and has no idea the rest of the app exists.
No asyncio, no cache, no logging of consequence. Its surface is `step()`,
`add_ticker()`, `remove_ticker()`, `get_price()`, `get_tickers()`, and `step()`
returns a plain `dict[str, float]`. This is what makes the maths testable: a
test seeds a known price, steps 10,000 times, and checks the distribution,
without touching an event loop.

**`SimulatorDataSource`** is the adapter. It implements `MarketDataSource`,
owns the asyncio task, and does nothing but call `step()` on an interval and
write the results into the `PriceCache`.

```python
async def _run_loop(self) -> None:
    while True:
        try:
            prices = self._sim.step()
            for ticker, price in prices.items():
                self._cache.update(ticker=ticker, price=price)
        except Exception:
            logger.exception("Simulator step failed")   # log, never exit
        await asyncio.sleep(self._interval)
```

The bare `except` around the step is one of the few defensive constructs worth
keeping. A task that raises exits silently, and the symptom is a frozen grid
with a green connection dot — indistinguishable from a working app on a quiet
market, and therefore very hard to diagnose.

`start()` seeds the cache with initial prices *before* creating the task, so
the first SSE client sees a populated grid rather than an empty one. `stop()`
cancels and awaits, swallowing `CancelledError`.

### Precision

Internal state (`self._prices`) keeps full float precision; only the value
returned from `step()` is rounded to 2dp. Rounding the state would compound
truncation error over thousands of ticks and, at a small enough `dt`, could
pin a price permanently by rounding every increment away.

---

## 5. Measured behaviour, and one problem

Numbers below are from the shipped code at `dt = 8.4792e-08`.

### Tick visibility: good

One standard deviation of a single tick:

| Ticker | sigma | per-tick 1sd | in dollars |
|---|---|---|---|
| AAPL | 0.22 | 0.0064% | $0.012 |
| JPM | 0.18 | 0.0052% | $0.010 |
| TSLA | 0.50 | 0.0146% | $0.036 |
| NVDA | 0.40 | 0.0117% | $0.093 |

Simulated over 20,000 ticks, the fraction where the **rounded** price actually
changes — that is, where the UI flashes:

| AAPL | JPM | TSLA | NVDA |
|---|---|---|---|
| 69.5% | 63.8% | 89.2% | 95.5% |

Comfortably alive without being frantic. Cheaper stocks flash less, which is
the right behaviour and an argument for keeping seed prices high enough that
two decimals stay meaningful — a $12 stock at sigma 0.18 would sit still.

### Drift over a demo: plausible

AAPL at $190, one standard deviation:

| Horizon | Move | Dollars |
|---|---|---|
| 10 s | 0.029% | $0.05 |
| 1 min | 0.070% | $0.13 |
| 5 min | 0.157% | $0.30 |
| 30 min | 0.384% | $0.73 |

A `Chg %` column reading a few tenths of a percent after half an hour is
exactly right for a real large cap.

### Shock events: miscalibrated

The shock process fires with probability 0.001 per ticker per tick, at
2-5% magnitude. Working that through:

| Tickers | Events/sec | One every | In a 10-min demo |
|---|---|---|---|
| 10 (today) | 0.020 | 50 s | 12 |
| 40 (planned) | 0.080 | 12.5 s | 48 |

Two things are wrong with that.

**The rate scales with the number of tickers.** PLAN.md commits to expanding
the allowlist to roughly forty symbols. Doing so quadruples the shock rate to
one every 12.5 seconds, because the probability is per ticker per tick. The
parameter that reads like "how often does something dramatic happen" is
actually "how often does something dramatic happen *per ticker*", and the
grid-level rate is an emergent side effect of the allowlist size.

**The magnitude dwarfs the diffusion.** AAPL's daily sigma is
`0.22/sqrt(252) = 1.39%`, so a 5% shock is **3.6 daily standard deviations** —
a genuine news event, arriving somewhere on the grid every 50 seconds today and
every 12.5 seconds after the expansion. Against 0.22% of GBM movement over ten
minutes, a single average shock of 3.5% is roughly **sixteen times** the entire
diffusion contribution. The price chart is not a random walk with occasional
drama; it is a step function with random-walk texture between the steps.

### Recommended fix

Specify the shock rate at the level it is reasoned about — the whole grid, per
unit time — and derive the per-tick probability from it:

```python
class GBMSimulator:
    SHOCK_EVENTS_PER_MINUTE = 1.0     # across the entire grid
    SHOCK_RANGE = (0.010, 0.025)      # 1.0% to 2.5%

    @property
    def _shock_prob_per_tick(self) -> float:
        """Per-ticker probability that keeps the grid-level rate constant."""
        n = len(self._tickers)
        if n == 0:
            return 0.0
        ticks_per_minute = 60.0 / self._interval
        return self.SHOCK_EVENTS_PER_MINUTE / (n * ticks_per_minute)
```

This holds the visible rate at about one event a minute whether ten tickers are
watched or forty, and 1-2.5% keeps a shock recognisable as an event — still
one to two daily sigma, a clear jump on the chart — without swamping the
process it is meant to decorate.

Both constants are presentation choices, not modelling ones. They should be
named constants that a person can tune while watching the screen, which is the
only way anyone will ever calibrate them.

---

## 6. Seed data and the allowlist

`seed_prices.py` holds data only, no logic:

```python
SEED_PRICES: dict[str, float]                 # realistic starting prices
TICKER_PARAMS: dict[str, dict[str, float]]    # per-ticker sigma and mu
DEFAULT_PARAMS: dict[str, float]              # fallback
CORRELATION_GROUPS: dict[str, set[str]]       # sector membership
```

Per-ticker parameters are what stop the grid looking uniform: TSLA at sigma
0.50 visibly jumps around, JPM and V at 0.17-0.18 barely move, NVDA carries the
strongest drift at mu 0.08. A viewer reads that as personality, and it costs a
table.

### The allowlist is a security boundary

PLAN.md section 6 is emphatic and correct: the allowlist is exactly
`SEED_PRICES.keys()`, and it is load-bearing rather than tidiness. The
simulator will invent a price for any string handed to it, so without the
allowlist `BANANA` becomes a tradable stock with a plausible chart — and the
LLM's `watch_add` executes without confirmation, one hallucinated symbol away
from a real position.

This has a direct implication for the code. The `random.uniform(50.0, 300.0)`
fallback in `_add_ticker_internal`, for tickers absent from `SEED_PRICES`, is
precisely the mechanism the allowlist exists to prevent. With the API boundary
enforcing the allowlist that line is unreachable, which is the design intent —
but "unreachable" is a claim about code elsewhere, and the safer expression of
the same intent is to raise:

```python
def _add_ticker_internal(self, ticker: str) -> None:
    if ticker not in SEED_PRICES:
        raise KeyError(f"{ticker} is not on the allowlist")
```

A loud failure in the one path that must never silently succeed. If the API
boundary is ever bypassed or refactored, this turns a fabricated tradable stock
into a stack trace.

### Expanding to forty

PLAN.md leaves this open, noting only that whoever expands `SEED_PRICES` sets
the universe. The constraints that expansion must respect:

- Every symbol needs a seed price **and** a `TICKER_PARAMS` entry. Falling
  through to `DEFAULT_PARAMS` gives an identical-looking ticker.
- Every symbol needs a `CORRELATION_GROUPS` membership, or it lands at the
  0.3 cross-sector default and drifts alone.
- Keep intra-group rho above cross-group rho, per section 3.
- Prefer names above roughly $30 so two decimals stay expressive.
- Seed prices only need to be plausible, not current. They are a starting
  point for a random walk, and the app makes no claim that they are real. A
  comment recording when they were taken is worth more than accuracy.

Sector groups worth adding alongside tech and finance: healthcare, energy,
consumer, industrials. Four to eight names each, with sigma between 0.15 and
0.30 outside tech, gives the grid visible variety.

---

## 7. Testing

Distributional tests are the substance here; a single step tells you nothing
about a stochastic process.

- **Distribution.** Over ~10,000 steps from a known seed, the mean and standard
  deviation of log returns match `mu·dt` and `sigma·sqrt(dt)` within tolerance.
  Seed the RNG and pick a tolerance that will not flake — this is the test most
  likely to fail spuriously in CI.
- **Positivity.** Prices stay above zero across a long run, including at
  sigma 0.50.
- **Correlation.** Over many steps, the realised correlation of tech pairs is
  near 0.6 and cross-sector pairs near 0.3.
- **Positive definiteness.** `np.linalg.eigvalsh(C).min() > 0` for the full
  allowlist, and for the matrix after every add and remove.
- **Shock rate.** With the fix in section 5, grid-level events per minute stay
  roughly constant at 10 and at 40 tickers. This is the test that would have
  caught the current miscalibration.
- **Allowlist.** Adding a ticker absent from `SEED_PRICES` raises rather than
  inventing a price.
- **Lifecycle.** `start` seeds the cache before returning; `add_ticker` yields a
  price immediately; `remove_ticker` evicts from the cache; the loop survives an
  induced exception in `step()`; `stop` is idempotent.

Determinism: `GBMSimulator` uses the module-level `random` and
`np.random.standard_normal`. Accepting an optional seeded
`np.random.Generator` in the constructor would make the distributional tests
reproducible and let the E2E suite pin a price path. Worth doing; it is a
constructor argument and a handful of call-site changes.

---

## 8. Summary of recommended changes

| Change | Section | Why |
|---|---|---|
| Derive shock probability from a grid-level rate | 5 | Otherwise expanding to 40 tickers quadruples the event rate |
| Reduce shock magnitude to 1.0-2.5% | 5 | 2-5% is up to 3.6 daily sigma and swamps the diffusion |
| Raise on tickers absent from `SEED_PRICES` | 6 | Removes the random-price fallback the allowlist exists to prevent |
| Assert positive definiteness over the allowlist | 3, 7 | A bad rho pair stops the backend starting, with an opaque error |
| Inject a seeded RNG | 7 | Makes distributional tests and E2E price paths reproducible |
| Expand `SEED_PRICES` to ~40 with params and groups | 6 | Outstanding item in PLAN.md |
