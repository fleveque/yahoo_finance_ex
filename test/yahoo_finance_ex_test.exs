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

      assert {:ok,
              %Quote{
                symbol: "AAPL",
                price: 187.42,
                currency: "USD",
                market_cap: 3_000_000_000,
                quote_type: "EQUITY"
              }} = YahooFinanceEx.get_quote("AAPL")
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
                      "industry" => "Consumer Electronics",
                      "website" => "https://www.apple.com",
                      "longBusinessSummary" => "Apple Inc. designs and sells smartphones."
                    }
                  }
                ]
              }
            })
        end
      end)

      assert {:ok,
              %{
                sector: "Technology",
                industry: "Consumer Electronics",
                website: "https://www.apple.com",
                description: "Apple Inc. designs and sells smartphones."
              }} = YahooFinanceEx.get_asset_profile("AAPL")
    end

    test "website + description are nil when the profile omits them" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/KO"} ->
            Req.Test.json(conn, %{
              "quoteSummary" => %{
                "result" => [%{"assetProfile" => %{"sector" => "Consumer Defensive"}}]
              }
            })
        end
      end)

      assert {:ok, %{sector: "Consumer Defensive", industry: nil, website: nil, description: nil}} =
               YahooFinanceEx.get_asset_profile("KO")
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

  describe "get_fund_profile/1" do
    test "returns expense ratio, AUM, category, holdings and sector weights for a fund" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/VHYL.AS"} ->
            Req.Test.json(conn, %{
              "quoteSummary" => %{
                "result" => [
                  %{
                    "fundProfile" => %{
                      "categoryName" => "Global Equity Income",
                      "family" => "Vanguard",
                      "feesExpensesInvestment" => %{
                        "annualReportExpenseRatio" => %{"raw" => 0.0029}
                      }
                    },
                    "defaultKeyStatistics" => %{
                      "totalAssets" => %{"raw" => 5_000_000_000},
                      "fundInceptionDate" => %{"raw" => 1_367_452_800, "fmt" => "2013-05-02"}
                    },
                    "topHoldings" => %{
                      "holdings" => [
                        %{
                          "symbol" => "AAPL",
                          "holdingName" => "Apple Inc",
                          "holdingPercent" => %{"raw" => 0.031}
                        },
                        %{
                          "symbol" => "JPM",
                          "holdingName" => "JPMorgan",
                          "holdingPercent" => %{"raw" => 0.021}
                        }
                      ],
                      "sectorWeightings" => [
                        %{"technology" => %{"raw" => 0.18}},
                        %{"financial_services" => %{"raw" => 0.155}},
                        %{"realestate" => %{"raw" => 0.04}}
                      ]
                    }
                  }
                ]
              }
            })
        end
      end)

      assert {:ok, profile} = YahooFinanceEx.get_fund_profile("VHYL.AS")
      assert profile.expense_ratio == 0.29
      assert profile.total_assets == 5_000_000_000.0
      assert profile.fund_category == "Global Equity Income"
      assert profile.fund_family == "Vanguard"
      assert profile.inception_date == ~D[2013-05-02]

      assert profile.top_holdings == [
               %{symbol: "AAPL", name: "Apple Inc", weight: 3.1},
               %{symbol: "JPM", name: "JPMorgan", weight: 2.1}
             ]

      assert profile.sector_weights == %{
               "Technology" => 18.0,
               "Financial Services" => 15.5,
               "Real Estate" => 4.0
             }
    end

    test "single stocks (no fundProfile module) are :not_found" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/AAPL"} ->
            Req.Test.json(conn, %{
              "quoteSummary" => %{"result" => [%{"assetProfile" => %{"sector" => "Technology"}}]}
            })
        end
      end)

      assert {:error, :not_found} = YahooFinanceEx.get_fund_profile("AAPL")
    end
  end

  describe "get_earnings_date/1" do
    test "returns a confirmed date" do
      stub_calendar_events("KO", %{
        "earnings" => %{
          "earningsDate" => [%{"raw" => 1_792_499_400, "fmt" => "2026-10-20"}],
          "isEarningsDateEstimate" => false
        }
      })

      assert {:ok, earnings} = YahooFinanceEx.get_earnings_date("KO")
      assert earnings.date == ~D[2026-10-20]
      assert earnings.date_end == nil
      refute earnings.estimated?
    end

    test "reports Yahoo's own estimate flag rather than flattening it" do
      stub_calendar_events("AAPL", %{
        "earnings" => %{
          "earningsDate" => [%{"raw" => 1_793_795_400, "fmt" => "2026-10-29"}],
          "isEarningsDateEstimate" => true
        }
      })

      assert {:ok, %{date: ~D[2026-10-29], estimated?: true}} =
               YahooFinanceEx.get_earnings_date("AAPL")
    end

    # Never observed live, but Yahoo has historically returned a two-element
    # range for unconfirmed reports — degrade into a range rather than
    # silently dropping the second date.
    test "a two-element range fills date_end" do
      stub_calendar_events("MMM", %{
        "earnings" => %{
          "earningsDate" => [
            %{"fmt" => "2026-10-20"},
            %{"fmt" => "2026-10-26"}
          ],
          "isEarningsDateEstimate" => true
        }
      })

      assert {:ok, %{date: ~D[2026-10-20], date_end: ~D[2026-10-26]}} =
               YahooFinanceEx.get_earnings_date("MMM")
    end

    # NESN.SW answers exactly this: the module is present, the list is empty,
    # and `isEarningsDateEstimate` is a meaningless `false`. Reading the flag
    # without checking the list would report a confirmed date that isn't there.
    test "an empty earningsDate is :not_found, not a confirmed date" do
      stub_calendar_events("NESN.SW", %{
        "earnings" => %{"earningsDate" => [], "isEarningsDateEstimate" => false}
      })

      assert {:error, :not_found} = YahooFinanceEx.get_earnings_date("NESN.SW")
    end

    test "a symbol with no calendarEvents module is :not_found" do
      stub_calendar_events("VWRL.AS", nil)

      assert {:error, :not_found} = YahooFinanceEx.get_earnings_date("VWRL.AS")
    end

    # ETFs, bond trackers and unknown symbols come back as HTTP 404 rather
    # than a 200 with an empty body — the common case for a fund, so it must
    # read as "there is none", not as a failed request.
    test "a 404 is :not_found, not an http_status error" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/SPY"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              404,
              ~s({"quoteSummary":{"result":null,"error":{"code":"Not Found"}}})
            )
        end
      end)

      assert {:error, :not_found} = YahooFinanceEx.get_earnings_date("SPY")
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

  describe "get_price_history/2" do
    test "returns date-sorted monthly closes, skipping null months" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v8/finance/chart/KO"} ->
            assert conn.query_params["interval"] == "1mo"

            Req.Test.json(conn, %{
              "chart" => %{
                "result" => [
                  %{
                    "timestamp" => [1_709_000_000, 1_711_000_000, 1_717_000_000],
                    "indicators" => %{
                      # Middle month is null → dropped; result stays date-sorted.
                      "quote" => [%{"close" => [44.5, nil, 47.0]}]
                    }
                  }
                ]
              }
            })
        end
      end)

      assert {:ok, [first, second]} = YahooFinanceEx.get_price_history("KO")
      assert first.close == 44.5
      assert second.close == 47.0
      assert Date.compare(first.date, second.date) == :lt
    end

    test "missing price series is {:ok, []}" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v8/finance/chart/GROW"} ->
            Req.Test.json(conn, %{"chart" => %{"result" => [%{}]}})
        end
      end)

      assert {:ok, []} = YahooFinanceEx.get_price_history("GROW")
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

  describe "get_news/2" do
    test "returns parsed headlines, most-recent first" do
      stub_yahoo(fn conn ->
        case {conn.host, conn.request_path} do
          {"fc.yahoo.com", _} ->
            cookie(conn)

          {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
            Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

          {"query1.finance.yahoo.com", "/v1/finance/search"} ->
            assert conn.params["q"] == "AAPL"
            assert conn.params["newsCount"] == "8"

            Req.Test.json(conn, %{
              "news" => [
                %{
                  "title" => "Older headline",
                  "link" => "https://news.example/old",
                  "publisher" => "Example Wire",
                  "providerPublishTime" => 1_700_000_000
                },
                %{
                  "title" => "Newest headline",
                  "link" => "https://news.example/new",
                  "publisher" => "Example Times",
                  "providerPublishTime" => 1_800_000_000
                },
                # No title → dropped.
                %{"link" => "https://news.example/untitled"}
              ]
            })
        end
      end)

      assert {:ok, [first, second]} = YahooFinanceEx.get_news("AAPL")
      assert first.title == "Newest headline"
      assert first.url == "https://news.example/new"
      assert first.publisher == "Example Times"
      assert %DateTime{} = first.published_at
      assert DateTime.compare(first.published_at, second.published_at) == :gt
    end

    test "no news is {:ok, []}" do
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

      assert {:ok, []} = YahooFinanceEx.get_news("ZZZZ")
    end
  end

  describe "get_option_chain/2" do
    test "parses calls and puts, tagged by side, with the spot and expiries" do
      stub_options(fn conn ->
        Req.Test.json(conn, option_payload())
      end)

      assert {:ok, chain} = YahooFinanceEx.get_option_chain("KO")

      assert chain.symbol == "KO"
      assert chain.spot == 62.15
      assert chain.currency == "USD"
      assert chain.expiry == ~D[2026-05-15]
      assert chain.expirations == [~D[2026-05-15], ~D[2026-06-19]]

      # The spot and the expiry list arrive in the same response as the
      # contracts, so a caller needs no second request for either.
      assert [call, put] = chain.contracts
      assert call.side == :call
      assert put.side == :put

      assert call.strike == 60.0
      assert call.bid == 3.1
      assert call.ask == 3.25
      assert call.open_interest == 1420
      assert call.implied_volatility == 0.2134
      assert call.in_the_money == true
      assert call.expiry == ~D[2026-05-15]
      assert call.last_trade_at == ~U[2026-05-05 14:30:00Z]
    end

    test "contract size is read from Yahoo's class name, not assumed" do
      # "REGULAR" means 100 shares and "MINI" means 10. Assuming 100 would
      # be wrong rather than merely unsupported for a mini contract.
      stub_options(fn conn ->
        Req.Test.json(conn, option_payload(call_overrides: %{"contractSize" => "MINI"}))
      end)

      assert {:ok, chain} = YahooFinanceEx.get_option_chain("KO")
      assert [%{contract_size: 10}, %{contract_size: 100}] = chain.contracts
    end

    test "an unrecognised contract size is nil rather than a guess" do
      stub_options(fn conn ->
        Req.Test.json(conn, option_payload(call_overrides: %{"contractSize" => "JUMBO"}))
      end)

      assert {:ok, chain} = YahooFinanceEx.get_option_chain("KO")
      assert [%{contract_size: nil} | _] = chain.contracts
    end

    test "a contract with no strike is dropped, not carried as a row of nils" do
      stub_options(fn conn ->
        Req.Test.json(conn, option_payload(call_overrides: %{"strike" => nil}))
      end)

      assert {:ok, chain} = YahooFinanceEx.get_option_chain("KO")
      assert [%{side: :put}] = chain.contracts
    end

    test "a symbol with no chain returns empty contracts, not an error" do
      # Yahoo answers 200 with no options block. That is "no chain", which a
      # caller must be able to tell apart from "the call failed".
      stub_options(fn conn ->
        Req.Test.json(conn, %{
          "optionChain" => %{"result" => [%{"underlyingSymbol" => "ZZZZ"}]}
        })
      end)

      assert {:ok, chain} = YahooFinanceEx.get_option_chain("ZZZZ")
      assert chain.contracts == []
      assert chain.expirations == []
      assert chain.spot == nil
    end

    test "an expiry is sent as a unix date parameter" do
      stub_options(fn conn ->
        assert conn.params["date"] == "1781827200"
        Req.Test.json(conn, option_payload())
      end)

      assert {:ok, _chain} = YahooFinanceEx.get_option_chain("KO", expiry: ~D[2026-06-19])
    end

    test "no expiry sends no date parameter, so Yahoo picks the nearest" do
      stub_options(fn conn ->
        refute Map.has_key?(conn.params, "date")
        Req.Test.json(conn, option_payload())
      end)

      assert {:ok, _chain} = YahooFinanceEx.get_option_chain("KO")
    end
  end

  defp stub_options(options_fun) do
    stub_yahoo(fn conn ->
      case {conn.host, conn.request_path} do
        {"fc.yahoo.com", _} ->
          cookie(conn)

        {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
          Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

        {"query1.finance.yahoo.com", "/v7/finance/options/KO"} ->
          options_fun.(Plug.Conn.fetch_query_params(conn))

        {"query1.finance.yahoo.com", "/v7/finance/options/ZZZZ"} ->
          options_fun.(Plug.Conn.fetch_query_params(conn))
      end
    end)
  end

  defp option_payload(opts \\ []) do
    call =
      Map.merge(
        %{
          "contractSymbol" => "KO260515C00060000",
          "strike" => 60.0,
          "expiration" => 1_778_803_200,
          "bid" => 3.1,
          "ask" => 3.25,
          "lastPrice" => 3.2,
          "volume" => 88,
          "openInterest" => 1420,
          "impliedVolatility" => 0.2134,
          "inTheMoney" => true,
          "contractSize" => "REGULAR",
          "currency" => "USD",
          "lastTradeDate" => 1_777_991_400
        },
        Keyword.get(opts, :call_overrides, %{})
      )

    put = %{
      "contractSymbol" => "KO260515P00055000",
      "strike" => 55.0,
      "expiration" => 1_778_803_200,
      "bid" => 0.95,
      "ask" => 1.05,
      "lastPrice" => 1.0,
      "volume" => 12,
      "openInterest" => 640,
      "impliedVolatility" => 0.1988,
      "inTheMoney" => false,
      "contractSize" => "REGULAR",
      "currency" => "USD",
      "lastTradeDate" => 1_777_991_400
    }

    %{
      "optionChain" => %{
        "result" => [
          %{
            "underlyingSymbol" => "KO",
            "expirationDates" => [1_778_803_200, 1_781_827_200],
            "strikes" => [55.0, 60.0],
            "quote" => %{"regularMarketPrice" => 62.15, "currency" => "USD"},
            "options" => [
              %{
                "expirationDate" => 1_778_803_200,
                "calls" => [call],
                "puts" => [put]
              }
            ]
          }
        ]
      }
    }
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

  # `calendar_events` nil = a 200 whose result carries no `calendarEvents`
  # module at all (as opposed to the 404 case, stubbed inline where used).
  defp stub_calendar_events(symbol, calendar_events) do
    result = if calendar_events, do: %{"calendarEvents" => calendar_events}, else: %{}

    stub_yahoo(fn conn ->
      case {conn.host, conn.request_path} do
        {"fc.yahoo.com", _} ->
          cookie(conn)

        {"query1.finance.yahoo.com", "/v1/test/getcrumb"} ->
          Plug.Conn.send_resp(conn, 200, "fake-crumb-abc")

        {"query1.finance.yahoo.com", "/v10/finance/quoteSummary/" <> _} ->
          assert conn.params["modules"] == "calendarEvents"
          Req.Test.json(conn, %{"quoteSummary" => %{"result" => [result]}})
      end
    end)

    symbol
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
              "dividendDate" => 1_708_473_600,
              "marketCap" => 3_000_000_000,
              "quoteType" => "EQUITY"
            }
          end)
      }
    }
  end
end
