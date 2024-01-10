defmodule Unzip.MixProject do
  use Mix.Project

  @version "0.10.0"
  @scm_url "https://github.com/akash-akya/unzip"

  def project do
    [
      app: :unzip,
      version: @version,
      elixir: "~> 1.5",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Package
      package: package(),
      description: description(),

      # Docs
      source_url: @scm_url,
      homepage_url: @scm_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Elixir library to stream zip file contents. Works with remote files. Supports Zip64"
  end

  defp package do
    [
      maintainers: ["Akash Hiremath"],
      licenses: ["MIT"],
      links: %{GitHub: "https://github.com/akash-akya/unzip"}
    ]
  end
end
