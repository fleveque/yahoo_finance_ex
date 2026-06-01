defmodule YahooFinanceEx do
  @moduledoc """
  Elixir client for Yahoo! Finance.

  v0.1 ships the smallest useful surface — a single-symbol quote fetch
  via Yahoo's `/v7/finance/quote` endpoint, with the cookie + CSRF crumb
  auth dance handled transparently by `YahooFinanceEx.Session`. Batched
  quotes, FX rates, dividend history, and symbol search are planned
  follow-ups.

  ## Quickstart

      {:ok, quote} = YahooFinanceEx.get_quote("AAPL")
      quote.price
      #=> 187.42

  All HTTP calls go through [`Req`](https://hexdocs.pm/req), so tests can
  stub responses via `Req.Test.stub/2`.

  ## Notes

  Yahoo's API is unofficial. Endpoints, auth requirements, and response
  shapes can change without notice. Two auth strategies are tried in
  order before erroring; sessions live for 60 seconds before being
  re-fetched.
  """

  alias YahooFinanceEx.{Quote, Session}

  @quote_path "/v7/finance/quote"
  @max_auth_retries 2

  @typedoc "Errors returned by the public functions."
  @type error ::
          {:auth_failed, term()}
          | {:http_status, non_neg_integer()}
          | {:transport, term()}
          | :not_found

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
         {:ok, body} <- do_get_quote(symbol, creds) do
      parse_quote_body(body, symbol)
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

  defp do_get_quote(symbol, creds) do
    url = creds.base_url <> @quote_path

    case YahooFinanceEx.HTTP.get(url,
           params: [symbols: symbol, crumb: creds.crumb],
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

  defp parse_quote_body(body, _symbol) when is_map(body) do
    case get_in(body, ["quoteResponse", "result"]) do
      [first | _] when is_map(first) -> {:ok, Quote.from_yahoo(first)}
      _ -> {:error, :not_found}
    end
  end
end
