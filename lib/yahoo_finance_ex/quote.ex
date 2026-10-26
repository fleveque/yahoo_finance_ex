defmodule YahooFinanceEx.Quote do
  @moduledoc """
  Parsed stock quote returned by `YahooFinanceEx.get_quote/1`.

  Fields mirror Yahoo's `/v7/finance/quote` response with derived values
  (`dividend_yield`, `payout_ratio`) computed locally.

  `dividend` is Yahoo's `dividendRate`, the forward annual rate, and is nil
  when Yahoo doesn't send it. Since October 2026 it is missing for most
  listings outside Germany. `dividend_yield` is then Yahoo's own
  `dividendYield` (a percentage, as Yahoo rounds it) rather than computed,
  and `payout_ratio` is nil. `trailing_annual_dividend` is Yahoo's
  `trailingAnnualDividendRate`, as sent: it is not a stand-in for the
  forward rate, and for many European listings it is far from it.

  `ex_dividend_date` is Yahoo's `exDividendDate`. Since October 2026 Yahoo
  leaves it out of `/v7/finance/quote` for every listing tried, so it is nil;
  `YahooFinanceEx.get_calendar_events/1` still has it. `dividend_date` is the
  payment date, never the ex-date.

  `financial_currency` is Yahoo's `financialCurrency`, the currency the
  company reports in. Where it differs from `currency`, the listing's, the
  dividend Yahoo shows is a conversion and moves with the exchange rate: on
  2026-10-26 MDO.F (McDonald's in Frankfurt, EUR, reports in USD) and RY
  (Royal Bank of Canada in New York, USD, reports in CAD). nil when Yahoo
  omits it.
  """

  @type t :: %__MODULE__{
          symbol: String.t(),
          name: String.t() | nil,
          price: float() | nil,
          currency: String.t() | nil,
          financial_currency: String.t() | nil,
          change: float() | nil,
          percent_change: float() | nil,
          volume: integer() | nil,
          pe_ratio: float() | nil,
          eps: float() | nil,
          dividend: float() | nil,
          dividend_yield: float() | nil,
          trailing_annual_dividend: float() | nil,
          payout_ratio: float() | nil,
          ma50: float() | nil,
          ma200: float() | nil,
          fifty_two_week_high: float() | nil,
          fifty_two_week_low: float() | nil,
          ex_dividend_date: Date.t() | nil,
          dividend_date: Date.t() | nil,
          market_cap: number() | nil,
          quote_type: String.t() | nil
        }

  defstruct [
    :symbol,
    :name,
    :price,
    :currency,
    :financial_currency,
    :change,
    :percent_change,
    :volume,
    :pe_ratio,
    :eps,
    :dividend,
    :dividend_yield,
    :trailing_annual_dividend,
    :payout_ratio,
    :ma50,
    :ma200,
    :fifty_two_week_high,
    :fifty_two_week_low,
    :ex_dividend_date,
    :dividend_date,
    :market_cap,
    :quote_type
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
      financial_currency: q["financialCurrency"],
      change: q["regularMarketChange"],
      percent_change: q["regularMarketChangePercent"],
      volume: q["regularMarketVolume"],
      pe_ratio: q["trailingPE"],
      eps: eps,
      dividend: dividend,
      dividend_yield: calculate_yield(dividend, price) || q["dividendYield"],
      trailing_annual_dividend: q["trailingAnnualDividendRate"],
      payout_ratio: calculate_payout(dividend, eps),
      ma50: q["fiftyDayAverage"],
      ma200: q["twoHundredDayAverage"],
      fifty_two_week_high: q["fiftyTwoWeekHigh"],
      fifty_two_week_low: q["fiftyTwoWeekLow"],
      ex_dividend_date: parse_unix_date(q["exDividendDate"]),
      dividend_date: parse_unix_date(q["dividendDate"]),
      market_cap: q["marketCap"],
      # Instrument kind, e.g. "EQUITY", "ETF", "MUTUALFUND", "INDEX",
      # "CURRENCY". Passed through verbatim; nil when Yahoo omits it.
      quote_type: q["quoteType"]
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
