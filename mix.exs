defmodule Plist.Mixfile do
  use Mix.Project

  @source_url "https://github.com/tv-labs/plist"
  @version "1.0.0"

  def project do
    [
      app: :plist,
      version: @version,
      description: "An Elixir library to encode and decode Apple's property list formats",
      elixir: "~> 1.15",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      package: package(),
      docs: docs(),
      source_url: @source_url,
      deps: deps()
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  def application do
    [extra_applications: [:xmerl]]
  end

  defp docs do
    [
      main: "Plist",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp package do
    [
      maintainers: ["Ciarán Walsh", "David Bernheisel"],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end
end
