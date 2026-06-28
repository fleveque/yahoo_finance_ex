defmodule YahooFinanceEx.MixProject do
  use Mix.Project

  @version "0.7.0"
  @source_url "https://github.com/fleveque/yahoo_finance_ex"

  def project do
    [
      app: :yahoo_finance_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "YahooFinanceEx",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {YahooFinanceEx.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:plug, "~> 1.16", only: :test}
    ]
  end

  defp description do
    "Elixir client for the Yahoo! Finance API. Handles the cookie + " <>
      "CSRF crumb auth flow transparently. Single + batched quotes, FX " <>
      "rates, asset profiles, dividend history, and symbol search."
  end

  defp package do
    [
      maintainers: ["Francesc Leveque"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "YahooFinanceEx",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
