defmodule TodoistBot.Commands do
  alias TodoistBot.Interaction
  alias TodoistBot.User
  alias TodoistBot.Repo

  def match(interaction) do
    case interaction do
      %{request: %{callback: "/logout.confirm.yes"}} ->
        logout_once(interaction)

        interaction
        |> Interaction.put_resp_text("Who are you? Do I know you?")
        |> Interaction.put_resp_type(:edit_text)

      %{request: %{text: "/help", is_command: true}} ->
        interaction
        |> Interaction.put_resp_text("""
        /help - show this help
        /about - about this bot
        /logout - make this bot forget you
        """)
        |> Interaction.put_resp_parse_mode_markdown()
        |> Interaction.put_resp_type(:message)

      %{request: %{text: "/about", is_command: true}} ->
        interaction
        |> Interaction.put_resp_text(
          "*Telegram for Todoist* is a simple bot for adding Inbox tasks through Telegram. This bot is created by @martosaur and is not created by, affiliated with, or supported by Doist. If you want to contribute please see [this repo](https://github.com/martosaur/todoist_bot)"
        )
        |> Interaction.put_resp_parse_mode_markdown()
        |> Interaction.put_resp_type(:message)

      %{request: %{text: "/logout", is_command: true}} ->
        interaction
        |> Interaction.put_resp_text(
          "Are you sure you want to logout and disappear without a trace from this bot's life?"
        )
        |> Interaction.add_resp_inline_keyboard()
        |> Interaction.add_resp_inline_keyboard_row()
        |> Interaction.add_resp_inline_keyboard_callback_button(
          "Yes",
          "/logout.confirm.yes"
        )
        |> Interaction.put_resp_type(:message)

      %{user: %{access_token: token} = user}
      when not is_nil(token) ->
        TodoistBot.Capture.run(interaction)
        |> case do
          {:ok, _task_id} ->
            interaction
            |> Interaction.put_resp_text("Task added")
            |> Interaction.put_resp_type(:message)

          {:error, :authorization} ->
            with {:ok, user} <-
                   user |> User.changeset(%{auth_code: nil, access_token: nil}) |> Repo.update() do
              %{interaction | user: user}
              |> request_authorization()
              |> Interaction.put_resp_text(
                "Todoist did not believe me and shut the door 😱 I'll have to authenticate you again."
              )
              |> Interaction.put_resp_type(:message)
            else
              _error ->
                interaction
                |> Interaction.put_resp_text(
                  "Something went terribly wrong 😢 Let's maybe try again?"
                )
                |> Interaction.put_resp_type(:message)
            end

          {:error, reason} ->
            text =
              case reason do
                :permission ->
                  "Todoist denied permission. Check upload plan limits; for an old task:add grant, /logout and authorize again with data:read_write, then reply /retry to the original message."

                :invalid_retry ->
                  "Reply /retry to your original text or attachment message, not to my reply."

                :unsupported ->
                  "Unsupported message: send text, a caption, or a supported file. Nothing added."

                :too_large ->
                  "Task saved, but attachment exceeds the configured #{TodoistBot.Attachment.limit()} byte limit. Send a smaller file."

                _ ->
                  "Could not finish saving. A task may already exist; reply /retry to the ORIGINAL message to resume without duplicating it."
              end

            interaction
            |> Interaction.put_resp_text(text)
            |> Interaction.put_resp_type(:message)
        end

      %{user: %{auth_code: nil}} ->
        interaction
        |> request_authorization()
        |> Interaction.put_resp_type(:message)

      _ ->
        interaction
        |> Interaction.put_resp_text("Did you say something?")
        |> Interaction.put_resp_type(:message)
    end
  end

  defp logout_once(i) do
    key =
      "logout:#{TodoistBot.Capture.namespace()}:#{i.user.telegram_id}:#{i.response.callback_query_id}"

    Repo.transaction(fn ->
      unless Repo.get(TodoistBot.Capture, key) do
        Repo.delete!(i.user)
        Repo.insert!(%TodoistBot.Capture{key: key, task_id: "done"})
      end
    end)
  end

  defp request_authorization(%Interaction{} = i) do
    i
    |> Interaction.put_resp_text("Please authorize this bot to access your account")
    |> Interaction.add_resp_inline_keyboard()
    |> Interaction.add_resp_inline_keyboard_row()
    |> Interaction.add_resp_inline_keyboard_link_button(
      "Authorize on Todoist",
      "#{Application.fetch_env!(:todoist_bot, :app_host)}authorize?uuid=#{i.user.auth_state}"
    )
    |> Interaction.add_resp_inline_keyboard_row()
  end
end
