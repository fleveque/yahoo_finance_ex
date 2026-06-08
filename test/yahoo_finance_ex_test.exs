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
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            Req.Test.json(conn, quote_payload([{"AAPL", 187.42}]))
        end
      end)

      assert {:ok, %Quote{symbol: "AAPL", price: 187.42, currency: "USD"}} =
               YahooFinanceEx.get_quote("AAPL")
    end

    test "returns :not_found when Yahoo returns an empty result list" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

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
            cookie(conn)

          {_, "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {_, "/v7/finance/quote"} ->
            Plug.Conn.send_resp(conn, 401, "")
        end
      end)

      assert {:error, {:auth_failed, :max_retries_exceeded}} = YahooFinanceEx.get_quote("AAPL")
    end
  end

  describe "get_quotes/1" do
    test "returns an empty map for an empty list (no HTTP call)" do
      assert {:ok, %{}} = YahooFinanceEx.get_quotes([])
    end

    test "returns each symbol's parsed quote keyed in the response map" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            Req.Test.json(
              conn,
              quote_payload([{"AAPL", 187.42}, {"MSFT", 400.0}])
            )
        end
      end)

      assert {:ok, results} = YahooFinanceEx.get_quotes(["AAPL", "MSFT"])
      assert {:ok, %Quote{symbol: "AAPL", price: 187.42}} = Map.fetch!(results, "AAPL")
      assert {:ok, %Quote{symbol: "MSFT", price: 400.0}} = Map.fetch!(results, "MSFT")
    end

    test "marks symbols Yahoo doesn't return as {:error, :not_found}" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            Req.Test.json(conn, quote_payload([{"AAPL", 187.42}]))
        end
      end)

      assert {:ok, results} = YahooFinanceEx.get_quotes(["AAPL", "FAKE"])
      assert {:ok, %Quote{symbol: "AAPL"}} = Map.fetch!(results, "AAPL")
      assert {:error, :not_found} = Map.fetch!(results, "FAKE")
    end

    test "dedupes the input list before requesting" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            symbols = conn.params["symbols"] || conn.query_params["symbols"]
            send(self(), {:symbols, symbols})
            Req.Test.json(conn, quote_payload([{"AAPL", 187.42}]))
        end
      end)

      assert {:ok, %{"AAPL" => {:ok, _}}} = YahooFinanceEx.get_quotes(["AAPL", "AAPL"])
      assert_received {:symbols, "AAPL"}
    end
  end

  describe "get_fx_rate/2" do
    test "short-circuits identity pairs to 1.0 without hitting the API" do
      # No stub registered — any HTTP would crash. Identity must skip it.
      assert {:ok, 1.0} = YahooFinanceEx.get_fx_rate("USD", "USD")
    end

    test "builds a Yahoo <FROM><TO>=X symbol and returns the price as the rate" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            symbols = conn.params["symbols"] || conn.query_params["symbols"]
            send(self(), {:symbols, symbols})
            Req.Test.json(conn, quote_payload([{"EURUSD=X", 1.08}]))
        end
      end)

      assert {:ok, 1.08} = YahooFinanceEx.get_fx_rate("EUR", "USD")
      assert_received {:symbols, "EURUSD=X"}
    end

    test "propagates :not_found when Yahoo has no quote for the pair" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v7/finance/quote"} ->
            Req.Test.json(conn, %{"quoteResponse" => %{"result" => []}})
        end
      end)

      assert {:error, :not_found} = YahooFinanceEx.get_fx_rate("XYZ", "ABC")
    end
  end

  ## Helpers

  defp stub_yahoo(fun) do
    Req.Test.stub(YahooFinanceEx.HTTPStub, fun)
    # The Session GenServer (started by the package's Application) lives
    # in its own process. Grant it access to this test's stub.
    Req.Test.allow(YahooFinanceEx.HTTPStub, self(), Process.whereis(YahooFinanceEx.Session))
    :ok
  end

  defp cookie(conn) do
    conn
    |> Plug.Conn.put_resp_header("set-cookie", "A1=fake-cookie; Path=/; Domain=.yahoo.com")
    |> Plug.Conn.send_resp(200, "")
  end

  defp quote_payload(symbol_prices) when is_list(symbol_prices) do
    %{
      "quoteResponse" => %{
        "result" =>
          Enum.map(symbol_prices, fn {symbol, price} ->
            %{
              "symbol" => symbol,
              "shortName" => "#{symbol} Inc.",
              "regularMarketPrice" => price,
              "currency" => "USD",
              "regularMarketChange" => 1.0,
              "regularMarketChangePercent" => 0.5,
              "regularMarketVolume" => 1_000_000,
              "trailingPE" => 25.0,
              "epsTrailingTwelveMonths" => 5.0,
              "dividendRate" => 1.0,
              "fiftyDayAverage" => price,
              "twoHundredDayAverage" => price,
              "fiftyTwoWeekHigh" => price * 1.2,
              "fiftyTwoWeekLow" => price * 0.8,
              "exDividendDate" => 1_707_955_200,
              "dividendDate" => 1_708_473_600
            }
          end)
      }
    }
  end
end
