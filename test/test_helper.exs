ExUnit.start()

# Route all Req calls in the library through Req.Test so individual tests
# can stub responses with Req.Test.stub/2.
Application.put_env(:yahoo_finance_ex, :req_options, plug: {Req.Test, YahooFinanceEx.HTTPStub})
