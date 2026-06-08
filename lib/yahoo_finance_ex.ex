defmodule YahooFinanceEx do
  @moduledoc """
  Elixir client for Yahoo! Finance.

  v0.2 surface:

    * `get_quote/1` — single-symbol quote.
    * `get_quotes/1` — batched quote fetch (up to 50 symbols per HTTP call;
      this function transparently batches larger lists).
    * `get_fx_rate/2` — current FX rate between two ISO 4217 currency codes
      via Yahoo's `<FROM><TO>=X` quote symbol.

  All paths go through `YahooFinanceEx.Session` to handle the cookie + CSRF
  crumb auth dance, and through `Req` for HTTP — so tests can stub the
  whole thing with `Req.Test`.

  Dividend history, symbol search, and an in-memory cache layer are
  planned follow-ups.

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

  defp fetch_quote_with_retry(symbol, attempt) do
    with {:ok, creds} <- Session.credentials(),
         {:ok, body} <- do_quote_request(symbol, creds) do
      parse_single_quote(body)
    else
      {:error, :unauthorized} when attempt < @max_auth_retries ->
        Session.invalidate()
        fetch_quote_with_retry(symbol, attempt + 1)

      {:error, :unauthorized} ->
        {:error, {:auth_failed, :max_retries_exceeded}}

      {:error, _} = err ->
        err
    end
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

  defp fetch_batch_with_retry(symbols, attempt) do
    with {:ok, creds} <- Session.credentials(),
         {:ok, body} <- do_quote_request(Enum.join(symbols, ","), creds) do
      {:ok, parse_batch_quote(body, symbols)}
    else
      {:error, :unauthorized} when attempt < @max_auth_retries ->
        Session.invalidate()
        fetch_batch_with_retry(symbols, attempt + 1)

      {:error, :unauthorized} ->
        {:error, {:auth_failed, :max_retries_exceeded}}

      {:error, _} = err ->
        err
    end
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

  ## Shared HTTP wrapper

  defp do_quote_request(symbols_param, creds) do
    url = creds.base_url <> @quote_path

    case YahooFinanceEx.HTTP.get(url,
           params: [symbols: symbols_param, crumb: creds.crumb],
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
