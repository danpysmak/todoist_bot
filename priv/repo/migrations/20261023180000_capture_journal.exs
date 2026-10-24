defmodule TodoistBot.Repo.Migrations.CaptureJournal do
  use Ecto.Migration
  def change do
    create table(:captures, primary_key: false) do
      add :key, :string, primary_key: true
      add :task_id, :string
      add :attachment, :map
      add :comment_id, :string
      add :title, :text
    end
    create table(:incoming_updates, primary_key: false) do
      add :key, :string, primary_key: true
      add :payload, :map, null: false
      add :done, :boolean, default: false, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
