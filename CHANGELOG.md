# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
