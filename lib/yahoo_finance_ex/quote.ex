defmodule YahooFinanceEx.Quote do
  @moduledoc """
  Parsed stock quote returned by `YahooFinanceEx.get_quote/1`.

  Fields mirror Yahoo's `/v7/finance/quote` response with derived values
  (`dividend_yield`, `payout_ratio`) computed locally.
  """

  @type t :: %__MODULE__{
          symbol: String.t(),
          name: String.t() | nil,
          price: float() | nil,
          currency: String.t() | nil,
          change: float() | nil,
          percent_change: float() | nil,
          volume: integer() | nil,
          pe_ratio: float() | nil,
          eps: float() | nil,
          dividend: float() | nil,
          dividend_yield: float() | nil,
          payout_ratio: float() | nil,
          ma50: float() | nil,
          ma200: float() | nil,
          fifty_two_week_high: float() | nil,
          fifty_two_week_low: float() | nil,
          ex_dividend_date: Date.t() | nil,
          dividend_date: Date.t() | nil
        }

  defstruct [
    :symbol,
    :name,
    :price,
    :currency,
    :change,
    :percent_change,
    :volume,
    :pe_ratio,
    :eps,
    :dividend,
    :dividend_yield,
    :payout_ratio,
    :ma50,
    :ma200,
    :fifty_two_week_high,
    :fifty_two_week_low,
    :ex_dividend_date,
    :dividend_date
  ]

  @doc false
  def from_yahoo(%{} = q) do
    price = q["regularMarketPrice"]
    dividend = q["dividendRate"]
    eps = q["epsTrailingTwelveMonths"]

    %__MODULE__{
      symbol: q["symbol"],
      name: q["shortName"],
      price: price,
      currency: q["currency"],
      change: q["regularMarketChange"],
      percent_change: q["regularMarketChangePercent"],
      volume: q["regularMarketVolume"],
      pe_ratio: q["trailingPE"],
      eps: eps,
      dividend: dividend,
      dividend_yield: calculate_yield(dividend, price),
      payout_ratio: calculate_payout(dividend, eps),
      ma50: q["fiftyDayAverage"],
      ma200: q["twoHundredDayAverage"],
      fifty_two_week_high: q["fiftyTwoWeekHigh"],
      fifty_two_week_low: q["fiftyTwoWeekLow"],
      ex_dividend_date: parse_unix_date(q["exDividendDate"]),
      dividend_date: parse_unix_date(q["dividendDate"])
    }
  end

  defp calculate_yield(dividend, price)
       when is_number(dividend) and is_number(price) and price > 0,
       do: Float.round(dividend / price * 100, 2)

  defp calculate_yield(_, _), do: nil

  defp calculate_payout(dividend, eps)
       when is_number(dividend) and is_number(eps) and eps > 0,
       do: Float.round(dividend / eps * 100, 2)

  defp calculate_payout(_, _), do: nil

  defp parse_unix_date(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value) do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  defp parse_unix_date(_), do: nil
end
