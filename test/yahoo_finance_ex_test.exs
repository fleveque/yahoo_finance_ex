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

  describe "get_asset_profile/1" do
    test "returns sector + industry from the assetProfile module" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/AAPL"} ->
            Req.Test.json(conn, %{
              "quoteSummary" => %{
                "result" => [
                  %{
                    "assetProfile" => %{
                      "sector" => "Technology",
                      "industry" => "Consumer Electronics"
                    }
                  }
                ]
              }
            })
        end
      end)

      assert {:ok, %{sector: "Technology", industry: "Consumer Electronics"}} =
               YahooFinanceEx.get_asset_profile("AAPL")
    end

    test "funds/ETFs (no profile or blank sector) are :not_found" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/VWCE.DE"} ->
            Req.Test.json(conn, %{
              "quoteSummary" => %{"result" => [%{"assetProfile" => %{"sector" => ""}}]}
            })
        end
      end)

      assert {:error, :not_found} = YahooFinanceEx.get_asset_profile("VWCE.DE")
    end
  end

  describe "get_financial_data/1" do
    test "returns leverage figures from the financialData module" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/AAPL"} ->
            Req.Test.json(conn, %{
              "quoteSummary" => %{
                "result" => [
                  %{
                    "financialData" => %{
                      "totalDebt" => %{"raw" => 118_760_996_864, "fmt" => "118.76B"},
                      "debtToEquity" => %{"raw" => 151.433, "fmt" => "151.43"},
                      "currentRatio" => %{"raw" => 0.953, "fmt" => "0.95"},
                      "quickRatio" => %{"raw" => 0.745, "fmt" => "0.75"},
                      "totalCash" => %{"raw" => 94_051_000_320, "fmt" => "94.05B"},
                      "ebitda" => %{"raw" => 77_305_004_032, "fmt" => "77.31B"}
                    }
                  }
                ]
              }
            })
        end
      end)

      assert {:ok, data} = YahooFinanceEx.get_financial_data("AAPL")
      assert data.total_debt == 1.18760996864e11
      assert data.debt_to_equity == 151.433
      assert data.current_ratio == 0.953
      assert data.quick_ratio == 0.745
      assert data.total_cash == 9.405100032e10
      assert data.ebitda == 7.7305004032e10
    end

    test "missing fields come back nil; absent module is :not_found" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/PARTIAL"} ->
            Req.Test.json(conn, %{
              "quoteSummary" => %{
                "result" => [%{"financialData" => %{"totalCash" => %{"raw" => 100}}}]
              }
            })

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/VWCE.DE"} ->
            Req.Test.json(conn, %{"quoteSummary" => %{"result" => [%{}]}})
        end
      end)

      assert {:ok, %{total_cash: 100.0, total_debt: nil, ebitda: nil}} =
               YahooFinanceEx.get_financial_data("PARTIAL")

      assert {:error, :not_found} = YahooFinanceEx.get_financial_data("VWCE.DE")
    end
  end

  describe "get_dividend_history/2" do
    test "returns date-sorted entries from the chart events stream" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v8/finance/chart/KO"} ->
            assert conn.query_params["events"] == "div"

            Req.Test.json(conn, %{
              "chart" => %{
                "result" => [
                  %{
                    "events" => %{
                      "dividends" => %{
                        # Deliberately unsorted; one malformed entry dropped.
                        "1717000000" => %{"date" => 1_717_000_000, "amount" => 0.485},
                        "1709000000" => %{"date" => 1_709_000_000, "amount" => 0.485},
                        "bad" => %{"date" => nil, "amount" => 0.485}
                      }
                    }
                  }
                ]
              }
            })
        end
      end)

      assert {:ok, [first, second]} = YahooFinanceEx.get_dividend_history("KO")
      assert first.amount == 0.485
      assert Date.compare(first.date, second.date) == :lt
    end

    test "no dividend events is {:ok, []}" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v8/finance/chart/GROW"} ->
            Req.Test.json(conn, %{"chart" => %{"result" => [%{"events" => %{}}]}})
        end
      end)

      assert {:ok, []} = YahooFinanceEx.get_dividend_history("GROW")
    end
  end

  describe "search/2" do
    test "returns parsed matches in Yahoo's order" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v1/finance/search"} ->
            assert conn.params["q"] == "coca cola"

            Req.Test.json(conn, %{
              "quotes" => [
                %{
                  "symbol" => "KO",
                  "shortname" => "Coca-Cola Company (The)",
                  "exchDisp" => "NYSE",
                  "quoteType" => "EQUITY"
                },
                %{
                  "symbol" => "CCEP",
                  "longname" => "Coca-Cola Europacific Partners PLC",
                  "exchange" => "NMS",
                  "quoteType" => "EQUITY"
                },
                # No symbol → dropped.
                %{"shortname" => "Mystery"}
              ]
            })
        end
      end)

      assert {:ok, [ko, ccep]} = YahooFinanceEx.search("coca cola")
      assert %{symbol: "KO", name: "Coca-Cola Company (The)", exchange: "NYSE"} = ko
      assert %{symbol: "CCEP", name: "Coca-Cola Europacific Partners PLC", exchange: "NMS"} = ccep
      assert ko.type == "EQUITY"
    end

    test "blank query short-circuits to {:ok, []} without HTTP" do
      # No stub installed — any HTTP call would crash the test.
      assert {:ok, []} = YahooFinanceEx.search("   ")
    end

    test "no matches is {:ok, []}" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v1/finance/search"} ->
            Req.Test.json(conn, %{"quotes" => []})
        end
      end)

      assert {:ok, []} = YahooFinanceEx.search("zzzzzz")
    end
  end

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
