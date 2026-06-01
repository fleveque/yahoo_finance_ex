defmodule YahooFinanceEx.HTTP do
  @moduledoc false
  # Single entry point for outbound HTTP. Wraps Req.get/2 so tests can
  # inject a `Req.Test` plug via Application config without each call
  # site repeating the override.

  def get(url, opts \\ []) do
    Req.get(url, Keyword.merge(default_opts(), opts))
  end

  defp default_opts do
    Application.get_env(:yahoo_finance_ex, :req_options, [])
  end
end
