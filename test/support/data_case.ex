defmodule MapsScraper.DataCase do
  @moduledoc """
  Dasar untuk test yang menyentuh database.

  Tiap test berjalan di dalam transaksi yang di-rollback setelahnya, jadi
  batch dan job yang dibuat satu test tidak pernah terlihat oleh test lain.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import MapsScraper.DataCase

      alias MapsScraper.Repo
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MapsScraper.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Menjalankan seluruh job yang menunggu sampai antreannya kosong.

  `with_scheduled` membuat job yang dijadwalkan ulang — baik karena retry
  maupun karena `snooze` — ikut dikerjakan sekarang, tanpa benar-benar
  menunggu jeda backoff-nya. Itulah sebabnya test retry di sini selesai dalam
  milidetik, bukan detik.
  """
  def drain do
    Oban.drain_queue(queue: :validation, with_scheduled: true, with_recursion: true)
  end
end
