# YahooFinanceEx

[![CI](https://github.com/fleveque/yahoo_finance_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/fleveque/yahoo_finance_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/yahoo_finance_ex.svg)](https://hex.pm/packages/yahoo_finance_ex)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/yahoo_finance_ex)

Elixir client for the Yahoo! Finance API. Handles Yahoo's cookie + CSRF crumb authentication transparently.

> ⚠️ **Yahoo's API is unofficial and undocumented.** Endpoints, auth requirements, and response shapes can change without notice. This library tracks the patterns that worked at the time of writing; expect occasional breakage.

## Status

v0.6 surface:

- `get_quote/1` — single-symbol quote.
- `get_quotes/1` — batched quote fetch (chunks of 50, returns a per-symbol result map).
- `get_fx_rate/2` — FX rate between two ISO 4217 codes via the `<FROM><TO>=X` ticker convention.
- `get_asset_profile/1` — company profile (sector, industry, website, description) via `quoteSummary`'s `assetProfile` module (v0.3; website + description added in v0.6).
- `get_dividend_history/2` — per-payment dividend history via the chart endpoint's `events=div` stream (v0.3).
- `search/2` — free-text ticker/company autocomplete via the `search` endpoint (v0.4).
- `get_financial_data/1` — leverage / balance-sheet figures (total debt, debt-to-equity, current & quick ratio, total cash, EBITDA) via `quoteSummary`'s `financialData` module (v0.5).
- `get_news/2` — recent news headlines via the `search` endpoint's `news` stream (v0.6).

Planned follow-ups (not yet implemented):

- in-memory caching with TTL

## Installation

```elixir
def deps do
  [
    {:yahoo_finance_ex, "~> 0.5"}
  ]
end
```

To track unreleased changes, you can point at the repo directly instead:

```elixir
def deps do
  [
    {:yahoo_finance_ex, github: "fleveque/yahoo_finance_ex"}
  ]
end
```

## Usage

```elixir
# Single symbol
{:ok, quote} = YahooFinanceEx.get_quote("AAPL")
quote.price            #=> 187.42

# Batched (chunks into groups of 50 internally)
{:ok, by_symbol} = YahooFinanceEx.get_quotes(["AAPL", "MSFT", "GOOG"])
by_symbol["AAPL"]      #=> {:ok, %YahooFinanceEx.Quote{...}}
by_symbol["FAKE"]      #=> {:error, :not_found}   # unknown symbols come back individually

# FX rate
{:ok, rate} = YahooFinanceEx.get_fx_rate("EUR", "USD")    #=> {:ok, 1.08}
{:ok, 1.0} = YahooFinanceEx.get_fx_rate("USD", "USD")     # identity short-circuits

# Company profile (funds and ETFs have none -> {:error, :not_found};
# website/description are nil when Yahoo omits them)
{:ok, profile} = YahooFinanceEx.get_asset_profile("AAPL")
profile.sector         #=> "Technology"
profile.website        #=> "https://www.apple.com"
profile.description    #=> "Apple Inc. designs and sells smartphones..."

# Dividend history (date-sorted; default range "2y")
{:ok, history} = YahooFinanceEx.get_dividend_history("KO")
hd(history)            #=> %{date: ~D[2024-03-15], amount: 0.485}

# Leverage / balance-sheet figures (funds and ETFs have none -> {:error, :not_found})
{:ok, financials} = YahooFinanceEx.get_financial_data("AAPL")
financials.debt_to_equity   #=> 151.4   # percentage, Yahoo's convention
financials.total_debt       #=> 1.087e11

# Recent news headlines (most-recent first; {:ok, []} when none)
{:ok, news} = YahooFinanceEx.get_news("AAPL", count: 5)
hd(news)                    #=> %{title: "...", url: "...", publisher: "...", published_at: ~U[...]}
```

Top-level errors (for the single-resource functions, plus aborted `get_quotes` calls) return `{:error, reason}` with one of:

- `:not_found` — Yahoo returned no quote for the symbol/pair
- `{:auth_failed, _}` — auth refresh failed after retries
- `{:http_status, status}` — non-200 HTTP status from Yahoo
- `{:transport, reason}` — network / transport error from Req

For `get_quotes/1`, partial failures (some symbols missing) surface inside the result map as `{:error, :not_found}` for those keys; the top-level call still returns `{:ok, map}`.

## Architecture

```
YahooFinanceEx           # public API
├── Session              # GenServer: holds (cookie, crumb), refreshes on demand (60 s TTL)
├── Quote                # struct returned by get_quote/1
└── HTTP                 # private: wraps Req so tests can inject stubs
```

`Session` is started under the package's own supervisor as soon as `:yahoo_finance_ex` is started — no manual setup needed.

## Testing your own code

All HTTP calls go through `Req`, so you can stub Yahoo's responses with `Req.Test`:

```elixir
test "fetches a quote" do
  Req.Test.stub(YahooFinanceEx.HTTPStub, fn conn ->
    Req.Test.json(conn, %{
      "quoteResponse" => %{"result" => [%{"symbol" => "AAPL", "regularMarketPrice" => 187.42, ...}]}
    })
  end)

  # ...
end
```

See `test/yahoo_finance_ex_test.exs` for full setup including the `Session` GenServer's allowances.

## License

MIT. See [LICENSE](LICENSE).
