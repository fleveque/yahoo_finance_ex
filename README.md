# YahooFinanceEx

Elixir client for the Yahoo! Finance API. Handles Yahoo's cookie + CSRF crumb authentication transparently.

> ⚠️ **Yahoo's API is unofficial and undocumented.** Endpoints, auth requirements, and response shapes can change without notice. This library tracks the patterns that worked at the time of writing; expect occasional breakage.

## Status

v0.1 ships the smallest useful surface: **single-symbol quote fetch**. Planned follow-ups (none yet implemented):

- batched quote fetch (`get_quotes/1`)
- FX rates (`get_fx_rate/2`)
- dividend history (`get_dividend_history/2`)
- symbol search (`search/2`)
- in-memory caching with TTL

## Installation

```elixir
def deps do
  [
    {:yahoo_finance_ex, "~> 0.1"}
  ]
end
```

Until published to Hex, use a git or path dependency:

```elixir
def deps do
  [
    {:yahoo_finance_ex, github: "fleveque/yahoo_finance_ex"}
  ]
end
```

## Usage

```elixir
{:ok, quote} = YahooFinanceEx.get_quote("AAPL")

quote.symbol           #=> "AAPL"
quote.price            #=> 187.42
quote.currency         #=> "USD"
quote.dividend_yield   #=> 0.51
quote.ma200            #=> 175.00
```

Errors return `{:error, reason}` with one of:

- `:not_found` — Yahoo returned an empty result for the symbol
- `{:auth_failed, _}` — auth refresh failed after retries
- `{:http_status, status}` — non-200 HTTP status from Yahoo
- `{:transport, reason}` — network / transport error from Req

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
