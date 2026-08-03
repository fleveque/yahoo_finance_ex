# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.11.0] - 2026-08-03

### Added

- `YahooFinanceEx.get_earnings_date/1` — the next scheduled earnings report
  for one symbol via the `quoteSummary` endpoint's `calendarEvents` module.
  Returns `%{date:, date_end:, estimated?:}`.

  `estimated?` carries Yahoo's own `isEarningsDateEstimate` flag: a date
  projected from the previous cycle rather than one the company has
  confirmed. Both states are common among large caps, and the difference
  matters to anyone timing a position around the report, so it is reported
  rather than flattened into a bare date.

  Verified against the live endpoint across 25 symbols, which corrected two
  things worth recording:

  - **`earningsDate` was never a range.** Every symbol returned zero or one
    entry, never the two-element range older write-ups describe. `estimated?`
    therefore reads the flag, not the entry count. A second entry is still
    surfaced as `date_end` so the historical shape degrades rather than
    losing a date, but it is not the signal.
  - **A symbol can carry the module with an empty `earningsDate`** (NESN.SW
    does), and `isEarningsDateEstimate` is `false` in that response — a
    default, not a fact. The list is checked before the flag is read, so a
    symbol with no date cannot report as a confirmed one.

  Coverage is not US-only: SAN.MC, DGE.L, BMW.DE, ALV.DE, ENEL.MI and
  GALP.LS all return dates, including names that have no option chain.

### Fixed

- **`authed_get` now maps HTTP 404 to `{:error, :not_found}`** instead of
  `{:error, {:http_status, 404}}`.

  Yahoo answers 404 both when it has no data for a symbol and when the
  requested `quoteSummary` module does not apply to it — `fundProfile` on an
  equity, `financialData` or `calendarEvents` on an ETF. `get_fund_profile/1`
  and `get_financial_data/1` have documented `{:error, :not_found}` for
  exactly those cases since 0.5/0.9, and only handled the variant where
  Yahoo replies 200 with the module missing from the body; the 404 variant
  escaped as a transport-shaped error.

  **Behaviour change:** a caller matching on `{:error, {:http_status, 404}}`
  now receives `{:error, :not_found}`. That is the contract these functions
  already promised. Callers that treat `:not_found` as "there is none" and
  other errors as "the fetch failed" get the intended behaviour for the
  first time — previously a normal absence could abort an enrichment pass.

### Changed

- The moduledoc's API list said "v0.9 surface" and omitted
  `get_option_chain/2` (added in 0.10). Both corrected.

## [0.10.0] - 2026-08-02

### Added

- `YahooFinanceEx.get_option_chain/2` — the option chain for one symbol and
  one expiry via `/v7/finance/options`. Calls and puts come back in a single
  `contracts` list, each tagged `side: :call | :put`, carrying strike,
  bid/ask, last price, volume, open interest, implied volatility, moneyness,
  currency and contract size.

  The response also includes every expiry Yahoo lists and the underlying's
  spot price, so one request answers "which expiries exist", "what is it
  trading at" and "what are the strikes" together — a consumer screening a
  shortlist needs one call per symbol, not three.

  `contract_size` is normalized from Yahoo's `"REGULAR"`/`"MINI"` class names
  to the share count they mean (100 / 10), and reported per contract rather
  than assumed — mini options and non-US listings are exactly the cases where
  assuming 100 is wrong rather than merely unsupported. An unrecognised class
  is `nil`, not a guess.

  A symbol with no chain returns `{:ok, chain}` with an empty `contracts`
  list rather than an error, so callers can tell "no options on this name"
  apart from "the request failed". Contracts without a strike are dropped
  rather than carried as rows of nils.

  Pass `:expiry` (a `Date`) to select an expiry other than the nearest.

## [0.9.0] - 2026-07-17

### Added

- `YahooFinanceEx.Quote.quote_type` — the instrument kind (`"EQUITY"`, `"ETF"`,
  `"MUTUALFUND"`, `"INDEX"`, …) passed through from the quote response's
  `quoteType`; `nil` when Yahoo omits it. Lets consumers distinguish funds from
  single stocks without a separate lookup.
- `YahooFinanceEx.get_fund_profile/1` — fund/ETF profile via `quoteSummary`'s
  `fundProfile`, `defaultKeyStatistics`, and `topHoldings` modules: expense
  ratio, total assets (AUM), category, family, inception date, top holdings
  (`%{symbol, name, weight}`), and sector weights (`%{sector => percent}`).
  Returns `{:error, :not_found}` for single stocks (no `fundProfile` module),
  so it doubles as an ETF discriminator. Expense-ratio and weight values are
  percentages.

## [0.8.0] - 2026-06-29

### Added

- `YahooFinanceEx.Quote.market_cap` — the stock's market capitalization
  (`marketCap` from the Yahoo quote response), parsed onto the quote struct.

## [0.7.0] - 2026-06-28

### Added

- `YahooFinanceEx.get_price_history/2` — monthly closing-price history via the
  chart endpoint (the price series alongside the dividend stream). Returns
  `%{date:, close:}` entries sorted ascending, skipping null months; `:range`
  defaults to `"6y"`. Pairs with `get_dividend_history/2` to build a historical
  yield band.

## [0.6.0] - 2026-06-28

### Added

- `YahooFinanceEx.get_news/2` — recent news headlines for a ticker via the
  `/v1/finance/search` endpoint's `news` stream. Returns
  `%{title:, url:, publisher:, published_at:}` entries (UTC `DateTime`),
  most-recent first; `{:ok, []}` when there's no news. Accepts `:count`
  (default 8).

### Changed

- `YahooFinanceEx.get_asset_profile/1` now also returns `website` and
  `description` (Yahoo's `longBusinessSummary`), each nil when absent —
  alongside the existing `sector`/`industry`. Funds/ETFs still return
  `{:error, :not_found}`.

## [0.5.0] - 2026-06-27

### Added

- `YahooFinanceEx.get_financial_data/1` — key leverage / balance-sheet
  figures (total debt, debt-to-equity, current ratio, quick ratio, total
  cash, EBITDA) via the `quoteSummary` endpoint's `financialData` module.
  Returns floats (or nil per missing field), `{:error, :not_found}` when a
  ticker exposes no `financialData`.

## [0.4.0] - 2026-06-12

### Added

- `YahooFinanceEx.search/2` — free-text ticker/company autocomplete via
  Yahoo's `/v1/finance/search` endpoint. Returns `{:ok, results}` with
  `%{symbol:, name:, exchange:, type:}` entries in Yahoo's relevance
  order; `type` is Yahoo's `quoteType` so callers can filter instrument
  kinds. Blank queries short-circuit to `{:ok, []}`.

## [0.3.0] - 2026-06-11

_(Entry backfilled — 0.3.0 shipped without a changelog entry.)_

### Added

- `YahooFinanceEx.get_asset_profile/1` — sector + industry via the
  `quoteSummary` endpoint's `assetProfile` module.
- `YahooFinanceEx.get_dividend_history/2` — per-payment dividend
  history via the chart endpoint's `events=div` stream; the raw
  material for payment-schedule inference. Accepts `:range` (default
  `"2y"`).

## [0.2.0] - 2026-06-08

### Added

- `YahooFinanceEx.get_quotes/1` — batched quote fetch for many symbols
  in one HTTP call. Transparently chunks lists into batches of 50
  (Yahoo's per-request ceiling). Returns `{:ok, %{symbol => result}}`
  where each result is `{:ok, Quote.t()}` or `{:error, :not_found}`.
- `YahooFinanceEx.get_fx_rate/2` — current FX rate between two ISO 4217
  currency codes via Yahoo's `<FROM><TO>=X` quote symbol. Short-circuits
  identity pairs (`get_fx_rate("USD", "USD")` returns `{:ok, 1.0}`)
  without hitting the API.

### Changed

- Package description tightened to reflect the v0.2 surface.

## [0.1.0] - 2026-06-01

### Added

- Initial release: Elixir port of the Ruby `yahoo_finance_client` gem.
- `YahooFinanceEx.get_quote/1` — fetch a single stock quote via Yahoo's
  `/v7/finance/quote` endpoint.
- `YahooFinanceEx.Session` GenServer — handles Yahoo's cookie + CSRF crumb
  auth dance with two fallback strategies (query1, query2). 60-second
  session TTL with on-demand refresh.
- `YahooFinanceEx.Quote` struct — typed result with derived fields
  (`dividend_yield`, `payout_ratio`) computed locally.
- Test stubbing via `Req.Test` so consumers can mock Yahoo responses
  without hitting the network.
