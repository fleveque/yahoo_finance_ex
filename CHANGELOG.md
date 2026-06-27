# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
