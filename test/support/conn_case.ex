defmodule MapsScraperWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest`. Antrean validasi tersimpan di SQLite,
  jadi tiap test dibungkus transaksi yang di-rollback setelahnya.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MapsScraperWeb.Endpoint

      use MapsScraperWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import MapsScraperWeb.ConnCase
      import MapsScraper.DataCase, only: [drain: 0]
    end
  end

  setup tags do
    MapsScraper.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
