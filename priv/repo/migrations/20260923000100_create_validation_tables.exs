defmodule MapsScraper.Repo.Migrations.CreateValidationTables do
  use Ecto.Migration

  def change do
    create table(:validation_batches, primary_key: false) do
      # Id dibuat aplikasi, bukan autoincrement: nilainya sudah menjadi bagian
      # dari API publik (`job_id`) sejak sebelum ada database.
      add :id, :string, primary_key: true
      add :source, :string, null: false
      add :opts, :map, null: false, default: %{}
      add :total, :integer, null: false
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:validation_rows) do
      add :batch_id, references(:validation_batches, type: :string, on_delete: :delete_all),
        null: false

      add :index, :integer, null: false
      add :query, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :result, :map
      add :error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:validation_rows, [:batch_id, :index])
    # Dipakai saat merangkum batch dan saat membuang batch lama.
    create index(:validation_rows, [:batch_id, :status])
    create index(:validation_batches, [:finished_at])
  end
end
