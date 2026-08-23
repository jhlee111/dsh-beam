defmodule DshBeam.Llm.Chat do
  @moduledoc """
  A chat consumer: declares :session and :llm. ask/2 appends the user message
  to the session log, completes it with the model over the committed session
  history, and appends the assistant reply.

  Both appends are revertible effects — withdrawing this fiber truncates them
  (recovery exactness), and losing either provider deactivates the chat first
  (the L-Unload guard).
  """

  use DshBeam.Plugin

  @doc "Ask the chat to answer one user message. Returns {:ok, %{content: text}}."
  def ask(chat, text) when is_pid(chat) and is_binary(text) do
    :gen_statem.call(chat, {:ask, text})
  end

  @impl DshBeam.Plugin
  def mount(_ctx, _opts) do
    {:ok, [:session, :llm], %{chat: self()}, %{}}
  end

  @impl true
  def handle_event({:call, from}, {:ask, text}, _state, data) do
    # Resolve against the context's current state, not the cached committed
    # view: after a withdrawal the view is deliberately retained (L-Unload),
    # so its pids may already be stale.
    result =
      case DshBeam.Context.resolve(data.ctx) do
        {:active, view} ->
          ask_llm(view.session, view.llm, text)

        {:inactive, _view} ->
          {:error, :capabilities_unavailable}

        :unknown ->
          {:error, :capabilities_unavailable}
      end

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  defp ask_llm(session, llm, text) do
    with {:ok, seq} <- DshBeam.Session.append(session, %{"role" => "user", "content" => text}),
         {:ok, messages} <- history_messages(session),
         {:ok, content} <- DshBeam.Llm.chat(llm, messages),
         {:ok, _reply_seq} <-
           DshBeam.Session.append(session, %{"role" => "assistant", "content" => content}) do
      {:ok, %{user_seq: seq, content: content}}
    end
  end

  defp history_messages(session) do
    # Session.all returns the raw event list (the seam's read shape)
    case DshBeam.Session.all(session) do
      events when is_list(events) ->
        {:ok,
         Enum.map(events, fn %{"role" => role, "content" => content} ->
           %{"role" => role, "content" => content}
         end)}

      other ->
        {:error, {:session_read, other}}
    end
  end
end
