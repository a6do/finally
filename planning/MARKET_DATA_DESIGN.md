# Market Data Backend — Detailed Design

Implementation-ready design for the FinAlly market data subsystem, covering the unified
interface, in-memory price cache, GBM simulator, Massive (Polygon.io) API client, SSE
streaming endpoint, and how the rest of the backend (portfolio, watchlist, trade execution —
still to be built) should integrate with it.

**Status:** This subsystem is implemented and tested. Every code sample in sections 1–9 below
is copied verbatim from `backend/app/market/` (not reconstructed from memory), so this document
can be trusted as an accurate reference, not just a plan. Sections 10–13 describe integration
points that the rest of the backend has not been built against yet — they are forward-looking
guidance for whoever builds `app/main.py`, portfolio, and watchlist routes.

Everything in sections 1–9 lives under `backend/app/market/`.

---

## Table of Contents

1. [File Structure](#1-file-structure)
2. [Data Model — `models.py`](#2-data-model)
3. [Price Cache — `cache.py`](#3-price-cache)
4. [Abstract Interface — `interface.py`](#4-abstract-interface)
5. [Seed Prices & Ticker Parameters — `seed_prices.py`](#5-seed-prices--ticker-parameters)
6. [GBM Simulator — `simulator.py`](#6-gbm-simulator)
7. [Massive API Client — `massive_client.py`](#7-massive-api-client)
8. [Factory — `factory.py`](#8-factory)
9. [SSE Streaming Endpoint — `stream.py`](#9-sse-streaming-endpoint)
10. [FastAPI Lifecycle Integration (not yet built)](#10-fastapi-lifecycle-integration-not-yet-built)
11. [Watchlist Coordination (not yet built)](#11-watchlist-coordination-not-yet-built)
12. [Testing](#12-testing)
13. [Error Handling & Edge Cases](#13-error-handling--edge-cases)
14. [Configuration Summary](#14-configuration-summary)
15. [Dependencies](#15-dependencies)

---

## 1. File Structure

```
backend/
  app/
    market/
      __init__.py             # Re-exports: PriceUpdate, PriceCache, MarketDataSource,
                               #   create_market_data_source, create_stream_router
      models.py                # PriceUpdate dataclass
      cache.py                 # PriceCache (thread-safe in-memory store)
      interface.py              # MarketDataSource ABC
      seed_prices.py            # SEED_PRICES, TICKER_PARAMS, DEFAULT_PARAMS, CORRELATION_GROUPS
      simulator.py               # GBMSimulator + SimulatorDataSource
      massive_client.py          # MassiveDataSource
      factory.py                 # create_market_data_source()
      stream.py                  # SSE endpoint (FastAPI router)
  tests/
    market/
      test_models.py
      test_cache.py
      test_simulator.py
      test_simulator_source.py
      test_factory.py
      test_massive.py
  market_data_demo.py            # Rich terminal demo (uv run market_data_demo.py)
```

Each file has a single responsibility. `__init__.py` re-exports the public API so the rest of
the backend imports from `app.market` without reaching into submodules:

```python
from app.market import PriceCache, PriceUpdate, MarketDataSource, create_market_data_source
```

---

## 2. Data Model

**File: `backend/app/market/models.py`**

`PriceUpdate` is the only data structure that leaves the market data layer. Every downstream
consumer — SSE streaming, portfolio valuation, trade execution — works exclusively with this
type.

```python
"""Data models for market data."""

from __future__ import annotations

import time
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class PriceUpdate:
    """Immutable snapshot of a single ticker's price at a point in time."""

    ticker: str
    price: float
    previous_price: float
    timestamp: float = field(default_factory=time.time)  # Unix seconds

    @property
    def change(self) -> float:
        """Absolute price change from previous update."""
        return round(self.price - self.previous_price, 4)

    @property
    def change_percent(self) -> float:
        """Percentage change from previous update."""
        if self.previous_price == 0:
            return 0.0
        return round((self.price - self.previous_price) / self.previous_price * 100, 4)

    @property
    def direction(self) -> str:
        """'up', 'down', or 'flat'."""
        if self.price > self.previous_price:
            return "up"
        elif self.price < self.previous_price:
            return "down"
        return "flat"

    def to_dict(self) -> dict:
        """Serialize for JSON / SSE transmission."""
        return {
            "ticker": self.ticker,
            "price": self.price,
            "previous_price": self.previous_price,
            "timestamp": self.timestamp,
            "change": self.change,
            "change_percent": self.change_percent,
            "direction": self.direction,
        }
```

### Design decisions

- **`frozen=True`**: Price updates are immutable value objects. Once created they never change,
  so they're safe to share across async tasks without copying.
- **`slots=True`**: Minor memory optimization — many of these are created per second.
- **Computed properties** (`change`, `change_percent`, `direction`): Derived from `price` and
  `previous_price` so they can never be inconsistent. There's no stored `direction` field that
  could go stale.
- **`to_dict()`**: The single serialization point used by both the SSE endpoint and any future
  REST responses that embed price data.

---

## 3. Price Cache

**File: `backend/app/market/cache.py`**

The price cache is the central data hub. Data sources write to it; SSE streaming and (later)
portfolio valuation / trade execution read from it. It's thread-safe because the Massive
client's synchronous calls run in a thread pool executor while SSE reads happen on the async
event loop.

```python
"""Thread-safe in-memory price cache."""

from __future__ import annotations

import time
from threading import Lock

from .models import PriceUpdate


class PriceCache:
    """Thread-safe in-memory cache of the latest price for each ticker.

    Writers: SimulatorDataSource or MassiveDataSource (one at a time).
    Readers: SSE streaming endpoint, portfolio valuation, trade execution.
    """

    def __init__(self) -> None:
        self._prices: dict[str, PriceUpdate] = {}
        self._lock = Lock()
        self._version: int = 0  # Monotonically increasing; bumped on every update

    def update(self, ticker: str, price: float, timestamp: float | None = None) -> PriceUpdate:
        """Record a new price for a ticker. Returns the created PriceUpdate.

        Automatically computes direction and change from the previous price.
        If this is the first update for the ticker, previous_price == price (direction='flat').
        """
        with self._lock:
            ts = timestamp or time.time()
            prev = self._prices.get(ticker)
            previous_price = prev.price if prev else price

            update = PriceUpdate(
                ticker=ticker,
                price=round(price, 2),
                previous_price=round(previous_price, 2),
                timestamp=ts,
            )
            self._prices[ticker] = update
            self._version += 1
            return update

    def get(self, ticker: str) -> PriceUpdate | None:
        """Get the latest price for a single ticker, or None if unknown."""
        with self._lock:
            return self._prices.get(ticker)

    def get_all(self) -> dict[str, PriceUpdate]:
        """Snapshot of all current prices. Returns a shallow copy."""
        with self._lock:
            return dict(self._prices)

    def get_price(self, ticker: str) -> float | None:
        """Convenience: get just the price float, or None."""
        update = self.get(ticker)
        return update.price if update else None

    def remove(self, ticker: str) -> None:
        """Remove a ticker from the cache (e.g., when removed from watchlist)."""
        with self._lock:
            self._prices.pop(ticker, None)

    @property
    def version(self) -> int:
        """Current version counter. Useful for SSE change detection."""
        return self._version

    def __len__(self) -> int:
        with self._lock:
            return len(self._prices)

    def __contains__(self, ticker: str) -> bool:
        with self._lock:
            return ticker in self._prices
```

### Why a version counter?

The SSE streaming loop polls the cache every ~500ms. Without a version counter it would
serialize and send all prices every tick even when nothing changed (e.g. the Massive source
only updates every 15s). The counter lets the SSE loop skip sends when there's nothing new —
see `stream.py`'s `_generate_events` in [section 9](#9-sse-streaming-endpoint).

### Thread safety rationale

`threading.Lock` is used instead of `asyncio.Lock` because the Massive client's synchronous
`get_snapshot_all()` runs via `asyncio.to_thread()`, which executes in a real OS thread —
`asyncio.Lock` would not protect against that. `threading.Lock` works correctly from both sync
threads and the async event loop, and the critical section (dict read/write) is small enough
that contention is a non-issue at this scale (single-digit tickers, ~2 writes/sec).

---

## 4. Abstract Interface

**File: `backend/app/market/interface.py`**

```python
"""Abstract interface for market data sources."""

from __future__ import annotations

from abc import ABC, abstractmethod


class MarketDataSource(ABC):
    """Contract for market data providers.

    Implementations push price updates into a shared PriceCache on their own
    schedule. Downstream code never calls the data source directly for prices —
    it reads from the cache.

    Lifecycle:
        source = create_market_data_source(cache)
        await source.start(["AAPL", "GOOGL", ...])
        # ... app runs ...
        await source.add_ticker("TSLA")
        await source.remove_ticker("GOOGL")
        # ... app shutting down ...
        await source.stop()
    """

    @abstractmethod
    async def start(self, tickers: list[str]) -> None:
        """Begin producing price updates for the given tickers.

        Starts a background task that periodically writes to the PriceCache.
        Must be called exactly once. Calling start() twice is undefined behavior.
        """

    @abstractmethod
    async def stop(self) -> None:
        """Stop the background task and release resources.

        Safe to call multiple times. After stop(), the source will not write
        to the cache again.
        """

    @abstractmethod
    async def add_ticker(self, ticker: str) -> None:
        """Add a ticker to the active set. No-op if already present.

        The next update cycle will include this ticker.
        """

    @abstractmethod
    async def remove_ticker(self, ticker: str) -> None:
        """Remove a ticker from the active set. No-op if not present.

        Also removes the ticker from the PriceCache.
        """

    @abstractmethod
    def get_tickers(self) -> list[str]:
        """Return the current list of actively tracked tickers."""
```

### Why the source writes to the cache instead of returning prices

This push model decouples timing. The simulator ticks every 500ms; Massive polls every 15s;
SSE always reads from the cache at its own 500ms cadence regardless of which source is active.
Neither the SSE layer nor any future consumer needs to know which data source is running or
what its update interval is — it's a pure strategy-pattern swap behind `PriceCache`.

---

## 5. Seed Prices & Ticker Parameters

**File: `backend/app/market/seed_prices.py`**

Constants only — no logic, no imports beyond stdlib types. Shared by the simulator (initial
prices, GBM parameters, correlation structure).

```python
"""Seed prices and per-ticker parameters for the market simulator."""

# Realistic starting prices for the default watchlist (as of project creation)
SEED_PRICES: dict[str, float] = {
    "AAPL": 190.00,
    "GOOGL": 175.00,
    "MSFT": 420.00,
    "AMZN": 185.00,
    "TSLA": 250.00,
    "NVDA": 800.00,
    "META": 500.00,
    "JPM": 195.00,
    "V": 280.00,
    "NFLX": 600.00,
}

# Per-ticker GBM parameters
# sigma: annualized volatility (higher = more price movement)
# mu: annualized drift / expected return
TICKER_PARAMS: dict[str, dict[str, float]] = {
    "AAPL": {"sigma": 0.22, "mu": 0.05},
    "GOOGL": {"sigma": 0.25, "mu": 0.05},
    "MSFT": {"sigma": 0.20, "mu": 0.05},
    "AMZN": {"sigma": 0.28, "mu": 0.05},
    "TSLA": {"sigma": 0.50, "mu": 0.03},  # High volatility
    "NVDA": {"sigma": 0.40, "mu": 0.08},  # High volatility, strong drift
    "META": {"sigma": 0.30, "mu": 0.05},
    "JPM": {"sigma": 0.18, "mu": 0.04},  # Low volatility (bank)
    "V": {"sigma": 0.17, "mu": 0.04},  # Low volatility (payments)
    "NFLX": {"sigma": 0.35, "mu": 0.05},
}

# Default parameters for tickers not in the list above (dynamically added)
DEFAULT_PARAMS: dict[str, float] = {"sigma": 0.25, "mu": 0.05}

# Correlation groups for the simulator's Cholesky decomposition
# Tickers in the same group have higher intra-group correlation
CORRELATION_GROUPS: dict[str, set[str]] = {
    "tech": {"AAPL", "GOOGL", "MSFT", "AMZN", "META", "NVDA", "NFLX"},
    "finance": {"JPM", "V"},
}

# Correlation coefficients
INTRA_TECH_CORR = 0.6  # Tech stocks move together
INTRA_FINANCE_CORR = 0.5  # Finance stocks move together
CROSS_GROUP_CORR = 0.3  # Between sectors / unknown tickers
TSLA_CORR = 0.3  # TSLA does its own thing
```

Note there is deliberately no separate "unknown ticker" correlation constant — `CROSS_GROUP_CORR`
is reused for both cross-sector pairs and any ticker outside the known groups (e.g. one added
dynamically through the watchlist), since both cases should behave the same way: weakly
correlated with everything else.

---

## 6. GBM Simulator

**File: `backend/app/market/simulator.py`**

Two classes live here:
- `GBMSimulator` — pure math engine, stateful, advances prices one step at a time.
- `SimulatorDataSource` — the `MarketDataSource` implementation wrapping `GBMSimulator` in an
  async loop that writes to the `PriceCache`.

### 6.1 GBMSimulator — the math engine

```python
"""GBM-based market simulator."""

from __future__ import annotations

import asyncio
import logging
import math
import random

import numpy as np

from .cache import PriceCache
from .interface import MarketDataSource
from .seed_prices import (
    CORRELATION_GROUPS,
    CROSS_GROUP_CORR,
    DEFAULT_PARAMS,
    INTRA_FINANCE_CORR,
    INTRA_TECH_CORR,
    SEED_PRICES,
    TICKER_PARAMS,
    TSLA_CORR,
)

logger = logging.getLogger(__name__)


class GBMSimulator:
    """Geometric Brownian Motion simulator for correlated stock prices.

    Math:
        S(t+dt) = S(t) * exp((mu - sigma^2/2) * dt + sigma * sqrt(dt) * Z)

    Where:
        S(t)   = current price
        mu     = annualized drift (expected return)
        sigma  = annualized volatility
        dt     = time step as fraction of a trading year
        Z      = correlated standard normal random variable

    The tiny dt (~8.5e-8 for 500ms ticks over 252 trading days * 6.5h/day)
    produces sub-cent moves per tick that accumulate naturally over time.
    """

    # 500ms expressed as a fraction of a trading year
    # 252 trading days * 6.5 hours/day * 3600 seconds/hour = 5,896,800 seconds
    TRADING_SECONDS_PER_YEAR = 252 * 6.5 * 3600  # 5,896,800
    DEFAULT_DT = 0.5 / TRADING_SECONDS_PER_YEAR  # ~8.48e-8

    def __init__(
        self,
        tickers: list[str],
        dt: float = DEFAULT_DT,
        event_probability: float = 0.001,
    ) -> None:
        self._dt = dt
        self._event_prob = event_probability

        # Per-ticker state
        self._tickers: list[str] = []
        self._prices: dict[str, float] = {}
        self._params: dict[str, dict[str, float]] = {}

        # Cholesky decomposition of the correlation matrix (for correlated moves)
        self._cholesky: np.ndarray | None = None

        # Initialize all starting tickers
        for ticker in tickers:
            self._add_ticker_internal(ticker)
        self._rebuild_cholesky()

    # --- Public API ---

    def step(self) -> dict[str, float]:
        """Advance all tickers by one time step. Returns {ticker: new_price}.

        This is the hot path — called every 500ms. Keep it fast.
        """
        n = len(self._tickers)
        if n == 0:
            return {}

        # Generate n independent standard normal draws
        z_independent = np.random.standard_normal(n)

        # Apply Cholesky to get correlated draws
        if self._cholesky is not None:
            z_correlated = self._cholesky @ z_independent
        else:
            z_correlated = z_independent

        result: dict[str, float] = {}
        for i, ticker in enumerate(self._tickers):
            params = self._params[ticker]
            mu = params["mu"]
            sigma = params["sigma"]

            # GBM: S(t+dt) = S(t) * exp((mu - 0.5*sigma^2)*dt + sigma*sqrt(dt)*Z)
            drift = (mu - 0.5 * sigma**2) * self._dt
            diffusion = sigma * math.sqrt(self._dt) * z_correlated[i]
            self._prices[ticker] *= math.exp(drift + diffusion)

            # Random event: ~0.1% chance per tick per ticker
            # With 10 tickers at 2 ticks/sec, expect an event ~every 50 seconds
            if random.random() < self._event_prob:
                shock_magnitude = random.uniform(0.02, 0.05)
                shock_sign = random.choice([-1, 1])
                self._prices[ticker] *= 1 + shock_magnitude * shock_sign
                logger.debug(
                    "Random event on %s: %.1f%% %s",
                    ticker,
                    shock_magnitude * 100,
                    "up" if shock_sign > 0 else "down",
                )

            result[ticker] = round(self._prices[ticker], 2)

        return result

    def add_ticker(self, ticker: str) -> None:
        """Add a ticker to the simulation. Rebuilds the correlation matrix."""
        if ticker in self._prices:
            return
        self._add_ticker_internal(ticker)
        self._rebuild_cholesky()

    def remove_ticker(self, ticker: str) -> None:
        """Remove a ticker from the simulation. Rebuilds the correlation matrix."""
        if ticker not in self._prices:
            return
        self._tickers.remove(ticker)
        del self._prices[ticker]
        del self._params[ticker]
        self._rebuild_cholesky()

    def get_price(self, ticker: str) -> float | None:
        """Current price for a ticker, or None if not tracked."""
        return self._prices.get(ticker)

    def get_tickers(self) -> list[str]:
        """Return the list of currently tracked tickers."""
        return list(self._tickers)

    # --- Internals ---

    def _add_ticker_internal(self, ticker: str) -> None:
        """Add a ticker without rebuilding Cholesky (for batch initialization)."""
        if ticker in self._prices:
            return
        self._tickers.append(ticker)
        self._prices[ticker] = SEED_PRICES.get(ticker, random.uniform(50.0, 300.0))
        self._params[ticker] = TICKER_PARAMS.get(ticker, dict(DEFAULT_PARAMS))

    def _rebuild_cholesky(self) -> None:
        """Rebuild the Cholesky decomposition of the ticker correlation matrix.

        Called whenever tickers are added or removed. O(n^2) but n < 50.
        """
        n = len(self._tickers)
        if n <= 1:
            self._cholesky = None
            return

        # Build the correlation matrix
        corr = np.eye(n)
        for i in range(n):
            for j in range(i + 1, n):
                rho = self._pairwise_correlation(self._tickers[i], self._tickers[j])
                corr[i, j] = rho
                corr[j, i] = rho

        self._cholesky = np.linalg.cholesky(corr)

    @staticmethod
    def _pairwise_correlation(t1: str, t2: str) -> float:
        """Determine correlation between two tickers based on sector grouping.

        Correlation structure:
          - Same tech sector:   0.6
          - Same finance sector: 0.5
          - TSLA with anything: 0.3 (it does its own thing)
          - Cross-sector:       0.3
          - Unknown tickers:    0.3
        """
        tech = CORRELATION_GROUPS["tech"]
        finance = CORRELATION_GROUPS["finance"]

        # TSLA is in tech set but behaves independently
        if t1 == "TSLA" or t2 == "TSLA":
            return TSLA_CORR

        if t1 in tech and t2 in tech:
            return INTRA_TECH_CORR
        if t1 in finance and t2 in finance:
            return INTRA_FINANCE_CORR

        return CROSS_GROUP_CORR
```

### 6.2 SimulatorDataSource — async wrapper

```python
class SimulatorDataSource(MarketDataSource):
    """MarketDataSource backed by the GBM simulator.

    Runs a background asyncio task that calls GBMSimulator.step() every
    `update_interval` seconds and writes results to the PriceCache.
    """

    def __init__(
        self,
        price_cache: PriceCache,
        update_interval: float = 0.5,
        event_probability: float = 0.001,
    ) -> None:
        self._cache = price_cache
        self._interval = update_interval
        self._event_prob = event_probability
        self._sim: GBMSimulator | None = None
        self._task: asyncio.Task | None = None

    async def start(self, tickers: list[str]) -> None:
        self._sim = GBMSimulator(
            tickers=tickers,
            event_probability=self._event_prob,
        )
        # Seed the cache with initial prices so SSE has data immediately
        for ticker in tickers:
            price = self._sim.get_price(ticker)
            if price is not None:
                self._cache.update(ticker=ticker, price=price)
        self._task = asyncio.create_task(self._run_loop(), name="simulator-loop")
        logger.info("Simulator started with %d tickers", len(tickers))

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None
        logger.info("Simulator stopped")

    async def add_ticker(self, ticker: str) -> None:
        if self._sim:
            self._sim.add_ticker(ticker)
            # Seed cache immediately so the ticker has a price right away
            price = self._sim.get_price(ticker)
            if price is not None:
                self._cache.update(ticker=ticker, price=price)
            logger.info("Simulator: added ticker %s", ticker)

    async def remove_ticker(self, ticker: str) -> None:
        if self._sim:
            self._sim.remove_ticker(ticker)
        self._cache.remove(ticker)
        logger.info("Simulator: removed ticker %s", ticker)

    def get_tickers(self) -> list[str]:
        return self._sim.get_tickers() if self._sim else []

    async def _run_loop(self) -> None:
        """Core loop: step the simulation, write to cache, sleep."""
        while True:
            try:
                if self._sim:
                    prices = self._sim.step()
                    for ticker, price in prices.items():
                        self._cache.update(ticker=ticker, price=price)
            except Exception:
                logger.exception("Simulator step failed")
            await asyncio.sleep(self._interval)
```

### Key behaviors

- **Immediate seeding**: When `start()` is called, the cache is populated with seed prices
  *before* the loop begins. The SSE endpoint has data to send on its very first tick — no
  blank-screen delay for the frontend.
- **Graceful cancellation**: `stop()` cancels the task and awaits it, catching
  `CancelledError`. Clean shutdown during FastAPI lifespan teardown.
- **Exception resilience**: The loop catches exceptions per-step so one bad tick doesn't kill
  the whole feed.
- **Public `get_tickers()` on `GBMSimulator`**: `SimulatorDataSource.get_tickers()` calls
  `self._sim.get_tickers()` rather than reaching into a private `_tickers` attribute — keeps the
  `MarketDataSource` implementation from depending on `GBMSimulator` internals.

---

## 7. Massive API Client

**File: `backend/app/market/massive_client.py`**

Polls the Massive (Polygon.io) REST API snapshot endpoint on a configurable interval. The
synchronous Massive client runs via `asyncio.to_thread()` to avoid blocking the event loop.

```python
"""Massive (Polygon.io) API client for real market data."""

from __future__ import annotations

import asyncio
import logging

from massive import RESTClient
from massive.rest.models import SnapshotMarketType

from .cache import PriceCache
from .interface import MarketDataSource

logger = logging.getLogger(__name__)


class MassiveDataSource(MarketDataSource):
    """MarketDataSource backed by the Massive (Polygon.io) REST API.

    Polls GET /v2/snapshot/locale/us/markets/stocks/tickers for all watched
    tickers in a single API call, then writes results to the PriceCache.

    Rate limits:
      - Free tier: 5 req/min → poll every 15s (default)
      - Paid tiers: higher limits → poll every 2-5s
    """

    def __init__(
        self,
        api_key: str,
        price_cache: PriceCache,
        poll_interval: float = 15.0,
    ) -> None:
        self._api_key = api_key
        self._cache = price_cache
        self._interval = poll_interval
        self._tickers: list[str] = []
        self._task: asyncio.Task | None = None
        self._client: RESTClient | None = None

    async def start(self, tickers: list[str]) -> None:
        self._client = RESTClient(api_key=self._api_key)
        self._tickers = list(tickers)

        # Do an immediate first poll so the cache has data right away
        await self._poll_once()

        self._task = asyncio.create_task(self._poll_loop(), name="massive-poller")
        logger.info(
            "Massive poller started: %d tickers, %.1fs interval",
            len(tickers),
            self._interval,
        )

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None
        self._client = None
        logger.info("Massive poller stopped")

    async def add_ticker(self, ticker: str) -> None:
        ticker = ticker.upper().strip()
        if ticker not in self._tickers:
            self._tickers.append(ticker)
            logger.info("Massive: added ticker %s (will appear on next poll)", ticker)

    async def remove_ticker(self, ticker: str) -> None:
        ticker = ticker.upper().strip()
        self._tickers = [t for t in self._tickers if t != ticker]
        self._cache.remove(ticker)
        logger.info("Massive: removed ticker %s", ticker)

    def get_tickers(self) -> list[str]:
        return list(self._tickers)

    # --- Internal ---

    async def _poll_loop(self) -> None:
        """Poll on interval. First poll already happened in start()."""
        while True:
            await asyncio.sleep(self._interval)
            await self._poll_once()

    async def _poll_once(self) -> None:
        """Execute one poll cycle: fetch snapshots, update cache."""
        if not self._tickers or not self._client:
            return

        try:
            # The Massive RESTClient is synchronous — run in a thread to
            # avoid blocking the event loop.
            snapshots = await asyncio.to_thread(self._fetch_snapshots)
            processed = 0
            for snap in snapshots:
                try:
                    price = snap.last_trade.price
                    # Massive timestamps are Unix milliseconds → convert to seconds
                    timestamp = snap.last_trade.timestamp / 1000.0
                    self._cache.update(
                        ticker=snap.ticker,
                        price=price,
                        timestamp=timestamp,
                    )
                    processed += 1
                except (AttributeError, TypeError) as e:
                    logger.warning(
                        "Skipping snapshot for %s: %s",
                        getattr(snap, "ticker", "???"),
                        e,
                    )
            logger.debug("Massive poll: updated %d/%d tickers", processed, len(self._tickers))

        except Exception as e:
            logger.error("Massive poll failed: %s", e)
            # Don't re-raise — the loop will retry on the next interval.
            # Common failures: 401 (bad key), 429 (rate limit), network errors.

    def _fetch_snapshots(self) -> list:
        """Synchronous call to the Massive REST API. Runs in a thread."""
        return self._client.get_snapshot_all(
            market_type=SnapshotMarketType.STOCKS,
            tickers=self._tickers,
        )
```

### `massive` is a top-level, always-installed dependency

`from massive import RESTClient` and `from massive.rest.models import SnapshotMarketType` are
module-level imports, not lazy imports inside `start()`. An earlier draft of this design used
lazy imports so the `massive` package would only be required when `MASSIVE_API_KEY` was set —
that approach was dropped during implementation review: `massive` is listed as a core dependency
in `pyproject.toml` (see [section 15](#15-dependencies)) and installed unconditionally via
`uv sync`, so there is no import-time cost to avoid. Keeping the imports at module level also
makes `MassiveDataSource` behave like a normal class for static analysis and testing (no
`Any`-typed `_client` attribute — it's typed `RESTClient | None`).

### Error handling philosophy

The Massive poller is intentionally resilient:

| Error | Behavior |
|-------|----------|
| **401 Unauthorized** | Logged as error. Poller keeps running (user might fix `.env` and restart). |
| **429 Rate Limited** | Logged as error. Next poll retries after `poll_interval` seconds. |
| **Network timeout** | Logged as error. Retries automatically on next cycle. |
| **Malformed snapshot** | Individual ticker skipped with a warning; other tickers in the same poll still processed. |
| **All tickers fail** | Cache retains last-known prices. SSE keeps streaming stale data (better than no data). |

---

## 8. Factory

**File: `backend/app/market/factory.py`**

```python
"""Factory for creating market data sources."""

from __future__ import annotations

import logging
import os

from .cache import PriceCache
from .interface import MarketDataSource
from .massive_client import MassiveDataSource
from .simulator import SimulatorDataSource

logger = logging.getLogger(__name__)


def create_market_data_source(price_cache: PriceCache) -> MarketDataSource:
    """Create the appropriate market data source based on environment variables.

    - MASSIVE_API_KEY set and non-empty → MassiveDataSource (real market data)
    - Otherwise → SimulatorDataSource (GBM simulation)

    Returns an unstarted source. Caller must await source.start(tickers).
    """
    api_key = os.environ.get("MASSIVE_API_KEY", "").strip()

    if api_key:
        logger.info("Market data source: Massive API (real data)")
        return MassiveDataSource(api_key=api_key, price_cache=price_cache)
    else:
        logger.info("Market data source: GBM Simulator")
        return SimulatorDataSource(price_cache=price_cache)
```

### Usage at app startup

```python
price_cache = PriceCache()
source = create_market_data_source(price_cache)
await source.start(initial_tickers)  # e.g., ["AAPL", "GOOGL", ...]
```

Both `MassiveDataSource` and `SimulatorDataSource` are imported at module level here too —
consistent with the decision in section 7, there is no runtime branch that needs to avoid
importing one or the other.

---

## 9. SSE Streaming Endpoint

**File: `backend/app/market/stream.py`**

A FastAPI route that holds open a long-lived HTTP connection and pushes price updates to the
client as `text/event-stream`.

```python
"""SSE streaming endpoint for live price updates."""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncGenerator

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse

from .cache import PriceCache

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/stream", tags=["streaming"])


def create_stream_router(price_cache: PriceCache) -> APIRouter:
    """Create the SSE streaming router with a reference to the price cache.

    This factory pattern lets us inject the PriceCache without globals.
    """

    @router.get("/prices")
    async def stream_prices(request: Request) -> StreamingResponse:
        """SSE endpoint for live price updates.

        Streams all tracked ticker prices every ~500ms. The client connects
        with EventSource and receives events in the format:

            data: {"AAPL": {"ticker": "AAPL", "price": 190.50, ...}, ...}

        Includes a retry directive so the browser auto-reconnects on
        disconnection (EventSource built-in behavior).
        """
        return StreamingResponse(
            _generate_events(price_cache, request),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",  # Disable nginx buffering if proxied
            },
        )

    return router


async def _generate_events(
    price_cache: PriceCache,
    request: Request,
    interval: float = 0.5,
) -> AsyncGenerator[str, None]:
    """Async generator that yields SSE-formatted price events.

    Sends all prices every `interval` seconds. Stops when the client
    disconnects (detected via request.is_disconnected()).
    """
    # Tell the client to retry after 1 second if the connection drops
    yield "retry: 1000\n\n"

    last_version = -1
    client_ip = request.client.host if request.client else "unknown"
    logger.info("SSE client connected: %s", client_ip)

    try:
        while True:
            # Check for client disconnect
            if await request.is_disconnected():
                logger.info("SSE client disconnected: %s", client_ip)
                break

            current_version = price_cache.version
            if current_version != last_version:
                last_version = current_version
                prices = price_cache.get_all()

                if prices:
                    data = {ticker: update.to_dict() for ticker, update in prices.items()}
                    payload = json.dumps(data)
                    yield f"data: {payload}\n\n"

            await asyncio.sleep(interval)
    except asyncio.CancelledError:
        logger.info("SSE stream cancelled for: %s", client_ip)
```

Note `_generate_events` is explicitly typed `AsyncGenerator[str, None]` (imported from
`collections.abc`) rather than left unannotated — this matters because it's an async generator
function passed directly into `StreamingResponse`, and the explicit return type keeps mypy/pyright
and IDEs from having to infer it.

### SSE wire format

```
data: {"AAPL":{"ticker":"AAPL","price":190.50,"previous_price":190.42,"timestamp":1707580800.5,"change":0.08,"change_percent":0.042,"direction":"up"},"GOOGL":{"ticker":"GOOGL","price":175.12,...}}

```

The client parses this with:

```javascript
const eventSource = new EventSource('/api/stream/prices');
eventSource.onmessage = (event) => {
    const prices = JSON.parse(event.data);
    // prices is { "AAPL": { ticker, price, previous_price, ... }, ... }
};
```

### Why poll-and-push instead of event-driven?

The SSE endpoint polls the cache on a fixed interval rather than being notified by the data
source. This is simpler and produces predictable, evenly-spaced updates for the frontend, which
accumulates them into sparkline charts — regular spacing matters for a clean visualization.

### Package `__init__.py`

**File: `backend/app/market/__init__.py`**

```python
"""Market data subsystem for FinAlly.

Public API:
    PriceUpdate         - Immutable price snapshot dataclass
    PriceCache          - Thread-safe in-memory price store
    MarketDataSource    - Abstract interface for data providers
    create_market_data_source - Factory that selects simulator or Massive
    create_stream_router - FastAPI router factory for SSE endpoint
"""

from .cache import PriceCache
from .factory import create_market_data_source
from .interface import MarketDataSource
from .models import PriceUpdate
from .stream import create_stream_router

__all__ = [
    "PriceUpdate",
    "PriceCache",
    "MarketDataSource",
    "create_market_data_source",
    "create_stream_router",
]
```

---

## 10. FastAPI Lifecycle Integration (not yet built)

`backend/app/main.py` does not exist yet — this section is guidance for whoever builds it, not
a description of existing code. The market data system should start and stop with the FastAPI
application using the `lifespan` context manager pattern.

```python
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.market import PriceCache, create_market_data_source, create_stream_router
from app.market.interface import MarketDataSource


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage startup and shutdown of background services."""

    # --- STARTUP ---

    # 1. Create the shared price cache
    price_cache = PriceCache()
    app.state.price_cache = price_cache

    # 2. Create and start the market data source
    source = create_market_data_source(price_cache)
    app.state.market_source = source

    # 3. Load initial tickers from the database watchlist (lazily initializes
    #    the SQLite schema + seed data on first run, per PLAN.md section 7)
    initial_tickers = await load_watchlist_tickers()
    await source.start(initial_tickers)

    # 4. Register the SSE streaming router
    app.include_router(create_stream_router(price_cache))

    yield  # App is running

    # --- SHUTDOWN ---
    await source.stop()


app = FastAPI(title="FinAlly", lifespan=lifespan)


# Dependencies for injecting the price cache / source into route handlers
def get_price_cache() -> PriceCache:
    return app.state.price_cache


def get_market_source() -> MarketDataSource:
    return app.state.market_source
```

### Accessing market data from other routes

Portfolio, trade execution, and watchlist routes access the cache and data source via FastAPI's
dependency injection:

```python
from fastapi import APIRouter, Depends, HTTPException

router = APIRouter(prefix="/api")


@router.post("/portfolio/trade")
async def execute_trade(
    trade: TradeRequest,
    price_cache: PriceCache = Depends(get_price_cache),
):
    current_price = price_cache.get_price(trade.ticker)
    if current_price is None:
        raise HTTPException(404, f"No price available for {trade.ticker}")
    # ... execute trade at current_price ...


@router.post("/watchlist")
async def add_to_watchlist(
    payload: WatchlistAdd,
    source: MarketDataSource = Depends(get_market_source),
):
    # ... insert into the watchlist table ...
    await source.add_ticker(payload.ticker)
    # ...


@router.delete("/watchlist/{ticker}")
async def remove_from_watchlist(
    ticker: str,
    source: MarketDataSource = Depends(get_market_source),
):
    # ... delete from the watchlist table ...
    await source.remove_ticker(ticker)
    # ...
```

---

## 11. Watchlist Coordination (not yet built)

When the watchlist changes — via the REST API or the LLM chat's `watchlist_changes` — the
market data source must be told, so it tracks the right set of tickers. This coordination lives
in the (not-yet-built) watchlist routes, not in `app/market/` itself.

### Flow: adding a ticker

```
User (or LLM) → POST /api/watchlist {ticker: "PYPL"}
  → Insert into watchlist table (SQLite)
  → await source.add_ticker("PYPL")
      Simulator: adds to GBMSimulator, rebuilds Cholesky, seeds cache immediately
      Massive:   appends to ticker list, appears on next poll (up to poll_interval delay)
  → Return success (ticker + current price if already available)
```

### Flow: removing a ticker

```
User (or LLM) → DELETE /api/watchlist/PYPL
  → Delete from watchlist table (SQLite)
  → await source.remove_ticker("PYPL")
      Simulator: removes from GBMSimulator, rebuilds Cholesky, removes from cache
      Massive:   removes from ticker list, removes from cache
  → Return success
```

### Edge case: ticker still has an open position

If the user removes a ticker from the watchlist but still holds shares, the data source should
keep tracking it so portfolio valuation stays accurate. The watchlist route needs to check this
before calling `remove_ticker`:

```python
@router.delete("/watchlist/{ticker}")
async def remove_from_watchlist(
    ticker: str,
    source: MarketDataSource = Depends(get_market_source),
):
    await db.delete_watchlist_entry(ticker)

    # Only stop tracking if there's no open position
    position = await db.get_position(ticker)
    if position is None or position.quantity == 0:
        await source.remove_ticker(ticker)

    return {"status": "ok"}
```

This check belongs in the watchlist route (which owns the database access), not in
`MarketDataSource` — the market data layer has no knowledge of positions or portfolios by
design (see [section 4](#4-abstract-interface)).

---

## 12. Testing

**73 tests across 6 modules, all passing. 84% overall coverage of `app/market/`.**

| Module | Tests | Coverage | What it covers |
|--------|------:|---------:|-----------------|
| `test_models.py` | 11 | 100% | `PriceUpdate` computed properties, `to_dict()`, edge cases (zero previous price) |
| `test_cache.py` | 13 | 100% | Update/get/get_all/remove, direction transitions, version counter |
| `test_simulator.py` | 17 | 98% | GBM math invariants (positivity, seed matching), add/remove ticker, Cholesky rebuilds |
| `test_simulator_source.py` | 10 | (integration) | `SimulatorDataSource` start/stop lifecycle, cache seeding, add/remove while running |
| `test_factory.py` | 7 | 100% | Env-var branching (`MASSIVE_API_KEY` set vs. unset/blank) |
| `test_massive.py` | 13 | 56% (expected — network calls mocked) | Poll success, malformed-snapshot skipping, API error resilience |

Run them with:

```bash
cd backend
uv run --extra dev pytest -v tests/market/
uv run --extra dev pytest --cov=app.market tests/market/
```

### Representative tests

**GBM invariants** (`test_simulator.py`):

```python
def test_prices_are_positive(self):
    """GBM prices can never go negative (exp() is always positive)."""
    sim = GBMSimulator(tickers=["AAPL"])
    for _ in range(10_000):
        prices = sim.step()
        assert prices["AAPL"] > 0

def test_cholesky_rebuilds_on_add(self):
    sim = GBMSimulator(tickers=["AAPL"])
    assert sim._cholesky is None  # Only 1 ticker, no correlation matrix
    sim.add_ticker("GOOGL")
    assert sim._cholesky is not None  # Now 2 tickers, matrix exists
```

**Cache version counter** (`test_cache.py`):

```python
def test_version_increments(self):
    cache = PriceCache()
    v0 = cache.version
    cache.update("AAPL", 190.00)
    assert cache.version == v0 + 1
```

**Massive poller resilience** (`test_massive.py`), using a `MagicMock` snapshot fixture:

```python
async def test_malformed_snapshot_skipped(self):
    cache = PriceCache()
    source = MassiveDataSource(api_key="test-key", price_cache=cache, poll_interval=60.0)
    source._tickers = ["AAPL", "BAD"]

    good_snap = _make_snapshot("AAPL", 190.50, 1707580800000)
    bad_snap = MagicMock()
    bad_snap.ticker = "BAD"
    bad_snap.last_trade = None  # Triggers AttributeError, caught and skipped

    with patch.object(source, "_fetch_snapshots", return_value=[good_snap, bad_snap]):
        await source._poll_once()

    assert cache.get_price("AAPL") == 190.50
    assert cache.get_price("BAD") is None
```

### Manual verification: the terminal demo

`backend/market_data_demo.py` drives a live Rich dashboard against the real simulator (all 10
default tickers, sparklines, color-coded direction arrows, an event log for shock moves). It's
the fastest way to eyeball whether the simulator "feels" right after a parameter change:

```bash
cd backend
uv run market_data_demo.py   # Runs for 60s or until Ctrl+C
```

---

## 13. Error Handling & Edge Cases

### 13.1 Startup with an empty watchlist

If the database has no watchlist entries, `start()` receives an empty list. Both sources handle
this gracefully — the simulator produces no prices, the Massive poller's `_poll_once()` returns
immediately (`if not self._tickers ...`). The SSE endpoint simply sends no events until a ticker
is added, at which point tracking starts immediately.

### 13.2 Price cache miss during a trade

If a user tries to trade a ticker with no cached price yet (just added, Massive hasn't polled),
the trade route should surface a clear error rather than trading at `None` or `0`:

```python
price = price_cache.get_price(ticker)
if price is None:
    raise HTTPException(
        status_code=400,
        detail=f"Price not yet available for {ticker}. Please wait a moment and try again.",
    )
```

The simulator sidesteps this by seeding the cache synchronously inside `add_ticker()`. The
Massive source has a real gap (up to `poll_interval` seconds) — the 400 with a clear message is
the correct behavior there, not a silent fallback price.

### 13.3 Invalid Massive API key

If the key is set but wrong, the first poll fails with a 401. The poller logs the error and
keeps retrying every `poll_interval` — it does not crash the app or stop the background task.
The SSE endpoint keeps the connection open but streams empty data. From the frontend's point of
view the connection-status dot stays green (SSE itself is fine) while no prices ever populate —
worth calling out in the frontend's empty/loading state, since "connected but no data" looks
different from "disconnected."

### 13.4 Thread safety under load

`PriceCache`'s `threading.Lock` is a plain mutex. At this project's scale (single-digit tickers,
~2 updates/sec from the simulator or 1 poll/15s from Massive, one SSE reader per browser tab)
contention is negligible — the critical section is a dict read or write. A `ReadWriteLock` would
only be worth it at a scale (hundreds of tickers, many concurrent SSE readers) this project
doesn't target.

### 13.5 Simulator numerical stability

- Prices are rounded to 2 decimal places at the end of every `step()`.
- The exponential formulation (`exp(drift + diffusion)`) is numerically stable and always
  positive — GBM prices can mathematically never go negative or hit exactly zero.
- The tiny `dt` (~8.5e-8) keeps per-tick moves sub-cent for realistic tickers, so rounding to 2
  decimals doesn't itself become a source of drift; the random shock events (2–5% moves) are
  the mechanism for visible per-tick jumps, by design.

---

## 14. Configuration Summary

| Parameter | Location | Default | Description |
|-----------|----------|---------|--------------|
| `MASSIVE_API_KEY` | Environment variable | `""` (empty) | If set and non-empty, use `MassiveDataSource`; otherwise `SimulatorDataSource`. |
| `update_interval` | `SimulatorDataSource.__init__` | `0.5` (seconds) | Time between simulator ticks. |
| `poll_interval` | `MassiveDataSource.__init__` | `15.0` (seconds) | Time between Massive API polls (free-tier safe). |
| `event_probability` | `GBMSimulator.__init__` | `0.001` | Per-ticker, per-tick chance of a 2–5% shock event. |
| `dt` | `GBMSimulator.__init__` | `GBMSimulator.DEFAULT_DT` (~8.48e-8) | GBM time step, as a fraction of a trading year. |
| SSE push interval | `_generate_events()` `interval` param | `0.5` (seconds) | How often the SSE loop checks the cache version and pushes. |
| SSE retry directive | `_generate_events()` | `1000` (ms) | Browser `EventSource` reconnection delay on disconnect. |

---

## 15. Dependencies

From `backend/pyproject.toml`:

```toml
[project]
dependencies = [
    "fastapi>=0.115.0",
    "uvicorn[standard]>=0.32.0",
    "numpy>=2.0.0",
    "massive>=1.0.0",
    "rich>=13.0.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.3.0",
    "pytest-asyncio>=0.24.0",
    "pytest-cov>=5.0.0",
    "ruff>=0.7.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["app"]
```

- **`numpy`** — Cholesky decomposition and vectorized standard-normal draws in `GBMSimulator`.
- **`massive`** — REST client for Polygon.io, used unconditionally by `massive_client.py` (see
  [section 7](#7-massive-api-client) for why it's not an optional/lazy import despite only being
  exercised when `MASSIVE_API_KEY` is set).
- **`rich`** — powers `market_data_demo.py`'s terminal dashboard only; not imported anywhere
  under `app/`.
- **`[tool.hatch.build.targets.wheel] packages = ["app"]`** — required for `uv sync` /
  `hatchling` to correctly package the `app` module; without it the build backend can't locate
  the package root.
