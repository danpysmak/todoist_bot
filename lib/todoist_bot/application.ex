defmodule TodoistBot.Application do
  use Application

  def start(_type, _args) do
    router =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: TodoistBot.Api,
        options: [port: Application.fetch_env!(:todoist_bot, :app_port)]
      )

    task_supervisor = {Task.Supervisor, name: TodoistBot.TaskSupervisor}

    TodoistBot.Release.migrate()

    opts = [strategy: :one_for_one, name: TodoistBot.Supervisor]
    Supervisor.start_link([TodoistBot.Repo, task_supervisor, router] ++ children(), opts)
  end

  if Mix.env() == :test do
    def children(), do: []
  else
    def children() do
      poller_or_webhook =
        if Application.get_env(:todoist_bot, :use_webhook) == "true" do
          %{
            id: WebhookSetup,
            start: {TodoistBot.Webhook, :setup_webhook, []},
            restart: :transient
          }
        else
          {TodoistBot.Poller, [Application.fetch_env!(:todoist_bot, :bot_token)]}
        end

      cleanup =
        if Application.get_env(:todoist_bot, :use_webhook) == "true",
          do: [],
          else: [
            %{
              id: WebhookCleanup,
              start: {TodoistBot.Webhook, :delete_webhook, []},
              restart: :transient
            }
          ]

      [TodoistBot.Inbox] ++ cleanup ++ [poller_or_webhook]
    end
  end
end
