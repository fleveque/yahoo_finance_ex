defmodule YahooFinanceExTest do
  use ExUnit.Case, async: false

  alias YahooFinanceEx.Quote

  setup do
    # Reset the singleton Session between tests so cached credentials
    # from a previous test don't bleed into this one.
    YahooFinanceEx.Session.invalidate()
    :ok
  end

  describe "get_quote/1" do
    test "returns a parsed quote on success" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            conn
            |> Plug.Conn.put_resp_header(
              "set-cookie",
              "A1=fake-cookie; Path=/; Domain=.yahoo.com"
            )
            |> Plug.Conn.send_resp(200, "")

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            Req.Test.json(conn, quote_payload("AAPL", 187.42))
        end
      end)

      assert {:ok, %Quote{symbol: "AAPL", price: 187.42, currency: "USD"}} =
               YahooFinanceEx.get_quote("AAPL")
    end

    test "returns :not_found when Yahoo returns an empty result list" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            conn
            |> Plug.Conn.put_resp_header("set-cookie", "A1=fake-cookie")
            |> Plug.Conn.send_resp(200, "")

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            Req.Test.json(conn, %{"quoteResponse" => %{"result" => []}})
        end
      end)

      assert {:error, :not_found} = YahooFinanceEx.get_quote("NOPE")
    end

    test "retries on 401 and surfaces :auth_failed when retries are exhausted" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            conn
            |> Plug.Conn.put_resp_header("set-cookie", "A1=fake-cookie")
            |> Plug.Conn.send_resp(200, "")

          {_, "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {_, "/v7/finance/quote"} ->
            Plug.Conn.send_resp(conn, 401, "")
        end
      end)

      assert {:error, {:auth_failed, :max_retries_exceeded}} = YahooFinanceEx.get_quote("AAPL")
    end
  end

  defp stub_yahoo(fun) do
    Req.Test.stub(YahooFinanceEx.HTTPStub, fun)
    # The Session GenServer (started by the package's Application) lives
    # in its own process. Grant it access to this test's stub.
    Req.Test.allow(YahooFinanceEx.HTTPStub, self(), Process.whereis(YahooFinanceEx.Session))
    :ok
  end

  defp quote_payload(symbol, price) do
    %{
      "quoteResponse" => %{
        "result" => [
          %{
            "symbol" => symbol,
            "shortName" => "Apple Inc.",
            "regularMarketPrice" => price,
            "currency" => "USD",
            "regularMarketChange" => 1.23,
            "regularMarketChangePercent" => 0.66,
            "regularMarketVolume" => 12_345_678,
            "trailingPE" => 30.5,
            "epsTrailingTwelveMonths" => 6.15,
            "dividendRate" => 0.96,
            "fiftyDayAverage" => 180.0,
            "twoHundredDayAverage" => 175.0,
            "fiftyTwoWeekHigh" => 199.0,
            "fiftyTwoWeekLow" => 150.0,
            "exDividendDate" => 1_707_955_200,
            "dividendDate" => 1_708_473_600
          }
        ]
      }
    }
  end
end
