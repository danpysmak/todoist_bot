defmodule TodoistBot.Repo.Migrations.InboxRetries do
  use Ecto.Migration
  def change do
    alter table(:incoming_updates) do
      add :attempts, :integer, default: 0, null: false
      add :next_attempt_at, :utc_datetime
    end
    create index(:incoming_updates, [:done, :next_attempt_at])
  end
end
