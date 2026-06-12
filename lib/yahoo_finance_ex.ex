defmodule YahooFinanceEx do
  @moduledoc """
  Elixir client for Yahoo! Finance.

  v0.4 surface:

    * `get_quote/1` — single-symbol quote.
    * `get_quotes/1` — batched quote fetch (up to 50 symbols per HTTP call;
      this function transparently batches larger lists).
    * `get_fx_rate/2` — current FX rate between two ISO 4217 currency codes
      via Yahoo's `<FROM><TO>=X` quote symbol.
    * `get_asset_profile/1` — sector + industry via the `quoteSummary`
      endpoint's `assetProfile` module (v0.3).
    * `get_dividend_history/2` — per-payment dividend history via the
      chart endpoint's `events=div` stream (v0.3); the raw material for
      payment-schedule inference.
    * `search/2` — free-text ticker/company autocomplete via the
      `search` endpoint (v0.4).

  All paths go through `YahooFinanceEx.Session` to handle the cookie + CSRF
  crumb auth dance, and through `Req` for HTTP — so tests can stub the
  whole thing with `Req.Test`.

  An in-memory cache layer is a planned follow-up.

  ## Quickstart

      {:ok, quote} = YahooFinanceEx.get_quote("AAPL")

      {:ok, by_symbol} = YahooFinanceEx.get_quotes(["AAPL", "MSFT", "GOOG"])
      by_symbol["AAPL"]
      #=> {:ok, %YahooFinanceEx.Quote{symbol: "AAPL", ...}}

      {:ok, rate} = YahooFinanceEx.get_fx_rate("EUR", "USD")
      #=> {:ok, 1.08}

  ## Notes

  Yahoo's API is unofficial. Endpoints, auth requirements, and response
  shapes can change without notice. Two auth strategies are tried in
  order before erroring; sessions live for 60 seconds before being
  re-fetched.
  """

  alias YahooFinanceEx.{Quote, Session}

  @quote_path "/v7/finance/quote"
  @quote_summary_path "/v10/finance/quoteSummary"
  @chart_path "/v8/finance/chart"
  @search_path "/v1/finance/search"
  @max_auth_retries 2
  @batch_size 50

  @typedoc "Errors returned by the public functions."
  @type error ::
          {:auth_failed, term()}
          | {:http_status, non_neg_integer()}
          | {:transport, term()}
          | :not_found

  @typedoc "Per-symbol result inside a batched `get_quotes/1` response."
  @type per_symbol_result :: {:ok, Quote.t()} | {:error, :not_found}

  @typedoc "One match returned by `search/2`."
  @type search_result :: %{
          symbol: String.t(),
          name: String.t(),
          exchange: String.t() | nil,
          type: String.t() | nil
        }

  ## get_quote/1

  @doc """
  Fetches a single stock quote.

  Returns `{:ok, %YahooFinanceEx.Quote{}}` on success, or `{:error, reason}`
  with one of the `t:error/0` shapes on failure.

  Retries once on transient auth errors (Yahoo invalidates sessions
  occasionally); deeper failures bubble up.
  """
  @spec get_quote(String.t()) :: {:ok, Quote.t()} | {:error, error()}
  def get_quote(symbol) when is_binary(symbol) do
    fetch_quote_with_retry(symbol, 0)
  end

  defp fetch_quote_with_retry(symbol, _attempt) do
    with_auth_retry(fn creds ->
      with {:ok, body} <- do_quote_request(symbol, creds) do
        parse_single_quote(body)
      end
    end)
  end

  defp parse_single_quote(body) when is_map(body) do
    case get_in(body, ["quoteResponse", "result"]) do
      [first | _] when is_map(first) -> {:ok, Quote.from_yahoo(first)}
      _ -> {:error, :not_found}
    end
  end

  ## get_quotes/1

  @doc """
  Fetches quotes for many symbols in one or more batched HTTP calls.

  Returns `{:ok, results_map}` where `results_map` is `%{symbol =>
  {:ok, Quote.t()} | {:error, :not_found}}` — i.e. each requested symbol
  is present in the map, mapped to its individual result. Symbols Yahoo
  doesn't recognize come back as `{:error, :not_found}`.

  Top-level errors (`{:auth_failed, _}`, `{:transport, _}`, etc.) abort
  the whole call and are returned as `{:error, reason}`.

  Symbols are batched in groups of #{@batch_size} (Yahoo's per-request
  ceiling). Duplicates and empty lists are tolerated.
  """
  @spec get_quotes([String.t()]) ::
          {:ok, %{String.t() => per_symbol_result()}} | {:error, error()}
  def get_quotes([]), do: {:ok, %{}}

  def get_quotes(symbols) when is_list(symbols) do
    symbols
    |> Enum.uniq()
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, acc} ->
      case fetch_batch_with_retry(batch, 0) do
        {:ok, batch_results} -> {:cont, {:ok, Map.merge(acc, batch_results)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp fetch_batch_with_retry(symbols, _attempt) do
    with_auth_retry(fn creds ->
      with {:ok, body} <- do_quote_request(Enum.join(symbols, ","), creds) do
        {:ok, parse_batch_quote(body, symbols)}
      end
    end)
  end

  defp parse_batch_quote(body, requested_symbols) when is_map(body) do
    found =
      body
      |> get_in(["quoteResponse", "result"])
      |> List.wrap()
      |> Map.new(fn raw -> {raw["symbol"], {:ok, Quote.from_yahoo(raw)}} end)

    Enum.reduce(requested_symbols, found, fn sym, acc ->
      Map.put_new(acc, sym, {:error, :not_found})
    end)
  end

  ## get_fx_rate/2

  @doc """
  Fetches the current FX rate between two ISO 4217 currency codes — one
  unit of `from` expressed in `to`.

  Returns `{:ok, 1.0}` for identity pairs without hitting the API.
  Returns `{:ok, rate}` (a float) on success, or `{:error, reason}` on
  failure (including `:not_found` when Yahoo has no quote for the pair).
  """
  @spec get_fx_rate(String.t(), String.t()) :: {:ok, float()} | {:error, error()}
  def get_fx_rate(currency, currency) when is_binary(currency), do: {:ok, 1.0}

  def get_fx_rate(from, to) when is_binary(from) and is_binary(to) do
    pair = String.upcase(from) <> String.upcase(to) <> "=X"

    case get_quote(pair) do
      {:ok, %Quote{price: price}} when is_number(price) -> {:ok, price * 1.0}
      {:ok, _} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  ## get_asset_profile/1

  @doc """
  Fetches the sector and industry for a ticker via Yahoo's
  `quoteSummary` endpoint (`assetProfile` module).

  Returns `{:ok, %{sector: sector, industry: industry}}` (industry may
  be nil), or `{:error, :not_found}` for funds, ETFs, and any symbol
  where Yahoo exposes no asset profile (a blank sector counts as none —
  matching the Ruby client's behavior).
  """
  @spec get_asset_profile(String.t()) ::
          {:ok, %{sector: String.t(), industry: String.t() | nil}} | {:error, error()}
  def get_asset_profile(symbol) when is_binary(symbol) do
    with_auth_retry(fn creds ->
      url = creds.base_url <> @quote_summary_path <> "/" <> URI.encode(symbol)

      with {:ok, body} <-
             authed_get(url, [modules: "assetProfile", crumb: creds.crumb], creds) do
        parse_asset_profile(body)
      end
    end)
  end

  defp parse_asset_profile(body) when is_map(body) do
    case get_in(body, ["quoteSummary", "result", Access.at(0), "assetProfile"]) do
      %{"sector" => sector} = profile when is_binary(sector) and sector != "" ->
        {:ok, %{sector: sector, industry: profile["industry"]}}

      _missing_or_blank ->
        {:error, :not_found}
    end
  end

  ## get_dividend_history/2

  @doc """
  Fetches the per-payment dividend history for a ticker via the chart
  endpoint's `events=div` stream.

  Returns `{:ok, entries}` — each entry `%{date: Date.t(), amount:
  float}`, sorted ascending by date — or `{:ok, []}` when the symbol
  pays no dividends (or Yahoo reports none for the range). Consumers
  infer payment schedules (frequency, months) from these entries.

  Options:

    * `:range` — Yahoo range string, default `"2y"` (enough to see a
      quarterly pattern twice).
  """
  @spec get_dividend_history(String.t(), keyword()) ::
          {:ok, [%{date: Date.t(), amount: float()}]} | {:error, error()}
  def get_dividend_history(symbol, opts \\ []) when is_binary(symbol) do
    range = Keyword.get(opts, :range, "2y")

    with_auth_retry(fn creds ->
      url = creds.base_url <> @chart_path <> "/" <> URI.encode(symbol)

      with {:ok, body} <-
             authed_get(
               url,
               [range: range, interval: "1mo", events: "div", crumb: creds.crumb],
               creds
             ) do
        {:ok, parse_dividend_history(body)}
      end
    end)
  end

  defp parse_dividend_history(body) when is_map(body) do
    case get_in(body, ["chart", "result", Access.at(0), "events", "dividends"]) do
      %{} = dividends ->
        dividends
        |> Map.values()
        |> Enum.flat_map(&parse_dividend_entry/1)
        |> Enum.sort_by(& &1.date, Date)

      _none ->
        []
    end
  end

  defp parse_dividend_entry(%{"date" => unix, "amount" => amount})
       when is_integer(unix) and is_number(amount) and amount > 0 do
    case DateTime.from_unix(unix) do
      {:ok, datetime} -> [%{date: DateTime.to_date(datetime), amount: amount * 1.0}]
      {:error, _} -> []
    end
  end

  defp parse_dividend_entry(_malformed), do: []

  ## search/2

  @doc """
  Searches Yahoo Finance for tickers matching a free-text query (a
  ticker fragment or a company name) via the `/v1/finance/search`
  autocomplete endpoint.

  Returns `{:ok, results}` — each result `%{symbol:, name:, exchange:,
  type:}`, in Yahoo's relevance order — or `{:ok, []}` for a blank
  query or no matches. `type` is Yahoo's `quoteType` (`"EQUITY"`,
  `"ETF"`, `"MUTUALFUND"`, `"INDEX"`, …) so callers can filter to the
  instruments they care about; `name` falls back `shortname` →
  `longname` → symbol.

  Options:

    * `:count` — max results to request, default 10.
  """
  @spec search(String.t(), keyword()) :: {:ok, [search_result()]} | {:error, error()}
  def search(query, opts \\ []) when is_binary(query) do
    count = Keyword.get(opts, :count, 10)

    case String.trim(query) do
      "" ->
        {:ok, []}

      normalized ->
        with_auth_retry(fn creds ->
          url = creds.base_url <> @search_path

          with {:ok, body} <-
                 authed_get(
                   url,
                   [q: normalized, quotesCount: count, newsCount: 0, crumb: creds.crumb],
                   creds
                 ) do
            {:ok, parse_search(body)}
          end
        end)
    end
  end

  defp parse_search(body) when is_map(body) do
    body
    |> Map.get("quotes")
    |> List.wrap()
    |> Enum.flat_map(&parse_search_quote/1)
  end

  defp parse_search_quote(%{"symbol" => symbol} = raw)
       when is_binary(symbol) and symbol != "" do
    [
      %{
        symbol: symbol,
        name: raw["shortname"] || raw["longname"] || symbol,
        exchange: raw["exchDisp"] || raw["exchange"],
        type: raw["quoteType"]
      }
    ]
  end

  defp parse_search_quote(_no_symbol), do: []

  ## Auth-retry wrapper — Yahoo invalidates sessions occasionally, so
  ## every endpoint retries once on 401 with fresh credentials.

  defp with_auth_retry(fun, attempt \\ 0) do
    with {:ok, creds} <- Session.credentials() do
      fun.(creds)
    end
    |> case do
      {:error, :unauthorized} when attempt < @max_auth_retries ->
        Session.invalidate()
        with_auth_retry(fun, attempt + 1)

      {:error, :unauthorized} ->
        {:error, {:auth_failed, :max_retries_exceeded}}

      other ->
        other
    end
  end

  ## Shared HTTP wrapper

  defp do_quote_request(symbols_param, creds) do
    url = creds.base_url <> @quote_path
    authed_get(url, [symbols: symbols_param, crumb: creds.crumb], creds)
  end

  defp authed_get(url, params, creds) do
    case YahooFinanceEx.HTTP.get(url,
           params: params,
           headers: [
             {"user-agent", Session.user_agent()},
             {"cookie", creds.cookie}
           ],
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end
end
