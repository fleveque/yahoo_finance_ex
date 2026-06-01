defmodule YahooFinanceEx.Session do
  @moduledoc """
  Holds Yahoo Finance auth state (cookie + CSRF crumb) for the running app.

  Yahoo's public API gates calls behind a per-session cookie and a crumb
  token that must be present on every request. This GenServer owns both,
  refreshes them when needed, and exposes a lookup function callers use
  before each HTTP call.

  Two strategies for obtaining a valid (cookie, crumb) pair are tried in
  order before giving up. Both rely on `Req` and are stubbable in tests
  via `Req.Test`.
  """

  use GenServer

  require Logger

  @session_ttl_seconds 60

  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/120.0.0.0"

  @cookie_url "https://fc.yahoo.com"
  @crumb_url_query1 "https://query1.finance.yahoo.com/v1/test/getcrumb"
  @crumb_url_query2 "https://query2.finance.yahoo.com/v1/test/getcrumb"

  defmodule Credentials do
    @moduledoc false
    defstruct [:cookie, :crumb, :base_url, :fetched_at]
  end

  ## Public API

  @doc """
  Starts the session GenServer. Started under the package's supervisor at
  app boot; not typically called directly.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `{:ok, %Credentials{}}` with a fresh-enough session, refreshing
  if the cached credentials are missing or expired.
  """
  @spec credentials(GenServer.server()) :: {:ok, Credentials.t()} | {:error, term()}
  def credentials(server \\ __MODULE__) do
    GenServer.call(server, :credentials, 15_000)
  end

  @doc """
  Marks the session as invalid so the next `credentials/0` call re-authenticates.
  Called after a 401 or auth-error response.
  """
  def invalidate(server \\ __MODULE__) do
    GenServer.cast(server, :invalidate)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    {:ok, %{credentials: nil}}
  end

  @impl true
  def handle_call(:credentials, _from, state) do
    case state.credentials do
      %Credentials{} = creds ->
        if fresh?(creds) do
          {:reply, {:ok, creds}, state}
        else
          authenticate_and_reply(state)
        end

      nil ->
        authenticate_and_reply(state)
    end
  end

  @impl true
  def handle_cast(:invalidate, state) do
    {:noreply, %{state | credentials: nil}}
  end

  defp authenticate_and_reply(state) do
    case authenticate() do
      {:ok, %Credentials{} = creds} ->
        {:reply, {:ok, creds}, %{state | credentials: creds}}

      {:error, reason} = err ->
        {:reply, err, state}
        |> tap(fn _ -> Logger.warning("YahooFinanceEx auth failed: #{inspect(reason)}") end)
    end
  end

  ## Authentication

  defp authenticate do
    strategies = [
      {&fetch_fc_cookie/0, @crumb_url_query1, "https://query1.finance.yahoo.com"},
      {&fetch_fc_cookie/0, @crumb_url_query2, "https://query2.finance.yahoo.com"}
    ]

    Enum.reduce_while(strategies, {:error, :all_strategies_failed}, fn {get_cookie, crumb_url,
                                                                        base_url},
                                                                       acc ->
      case try_strategy(get_cookie, crumb_url, base_url) do
        {:ok, _creds} = ok -> {:halt, ok}
        {:error, _reason} -> {:cont, acc}
      end
    end)
  end

  defp try_strategy(get_cookie, crumb_url, base_url) do
    with {:ok, cookie} <- get_cookie.(),
         {:ok, crumb} <- fetch_crumb(cookie, crumb_url),
         true <- valid_crumb?(crumb) do
      {:ok,
       %Credentials{
         cookie: cookie,
         crumb: crumb,
         base_url: base_url,
         fetched_at: System.monotonic_time(:second)
       }}
    else
      false -> {:error, :invalid_crumb}
      {:error, _} = err -> err
    end
  end

  defp fetch_fc_cookie do
    case YahooFinanceEx.HTTP.get(@cookie_url, headers: request_headers(), receive_timeout: 10_000) do
      {:ok, %Req.Response{headers: headers}} ->
        case extract_cookie(headers) do
          nil -> {:error, :no_cookie}
          cookie -> {:ok, cookie}
        end

      {:error, reason} ->
        {:error, {:cookie_request_failed, reason}}
    end
  end

  defp fetch_crumb(cookie, crumb_url) do
    case YahooFinanceEx.HTTP.get(crumb_url,
           headers: [{"cookie", cookie} | request_headers()],
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, String.trim(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:crumb_request_status, status}}

      {:error, reason} ->
        {:error, {:crumb_request_failed, reason}}
    end
  end

  defp extract_cookie(headers) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == "set-cookie", do: List.wrap(value)

      _ ->
        nil
    end)
    |> case do
      nil -> nil
      [] -> nil
      values -> values |> List.flatten() |> Enum.join("; ")
    end
  end

  defp valid_crumb?(crumb) when is_binary(crumb) do
    crumb != "" and not String.contains?(crumb, "<") and
      not String.contains?(crumb, "Unauthorized")
  end

  defp valid_crumb?(_), do: false

  defp fresh?(%Credentials{fetched_at: at}) do
    System.monotonic_time(:second) - at < @session_ttl_seconds
  end

  defp request_headers do
    [
      {"user-agent", @user_agent},
      {"accept", "text/html,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.5"}
    ]
  end

  @doc false
  def user_agent, do: @user_agent
end
