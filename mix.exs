defmodule Unzip.MixProject do
  use Mix.Project

  def project do
    [
      app: :unzip,
      version: "0.4.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Package
      package: package(),
      description: description(),

      # Docs
      source_url: "https://github.com/akash-akya/unzip",
      homepage_url: "https://github.com/akash-akya/unzip",
      docs: [
        main: "readme",
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
    [{:ex_doc, ">= 0.0.0", only: :dev}]
  end

  defp description do
    "Module to get files out of a zip. Works with local and remote files. Supports Zip64"
  end

  defp package do
    [
      maintainers: ["Akash Hiremath"],
      licenses: ["MIT"],
      links: %{GitHub: "https://github.com/akash-akya/unzip"}
    ]
  end
end
