defmodule DshBeam.Workspace do
  @moduledoc """
  The workspace capability: groups sessions by their working directory and lets
  a session address its peers.

  A session registers itself with the workspace (via `register/2`, called by
  the session fiber on mount). Sessions sharing a `cwd` "know" each other: the
  same working directory is the workspace, and `peers/2` returns every other
  session there. A user (or the agent, via a tool) can then ask one session to
  collaborate with another — `relay/3` appends a peer message to the target
  session's log, which its loop sees as an incoming user turn.

  This is the minimal port of the reference `agent-team` peer mailbox: a flat
  roster, message delivery by appending to the target's log, no task DAG.

  Each session's worktree is the isolation boundary (git worktree), but the
  *workspace* is the shared directory identity that sessions group under.
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, _opts) do
    {:ok, [], %{workspace: self()}, %{by_cwd: %{}}}
  end

  @doc "Register a session under its working directory."
  def register(workspace, session, cwd) when is_pid(workspace) and is_pid(session) do
    :gen_statem.call(workspace, {:register, session, cwd})
  end

  @doc "Drop a session from the roster."
  def unregister(workspace, session) when is_pid(workspace) and is_pid(session) do
    :gen_statem.call(workspace, {:unregister, session})
  end

  @doc "Every session in a working directory (including `session` itself)."
  def sessions(workspace, cwd) when is_pid(workspace) do
    :gen_statem.call(workspace, {:sessions, cwd})
  end

  @doc "The other sessions in `session`'s directory — the peers it can collaborate with."
  def peers(workspace, session) when is_pid(workspace) and is_pid(session) do
    :gen_statem.call(workspace, {:peers, session})
  end

  @doc """
  Relay a peer message from `from` to `to`: appends a `peer_message` event to
  the target's log. Both must share a working directory (a workspace), otherwise
  it is refused.
  """
  def relay(workspace, from, to, content)
      when is_pid(workspace) and is_pid(from) and is_pid(to) and is_binary(content) do
    :gen_statem.call(workspace, {:relay, from, to, content})
  end

  @impl true
  def handle_event({:call, from}, {:register, session, cwd}, _state, data) do
    by_cwd =
      Map.update(data.extra.by_cwd, cwd, [session], fn sessions -> [session | sessions] end)

    {:keep_state, %{data | extra: %{by_cwd: by_cwd}}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:unregister, session}, _state, data) do
    by_cwd =
      Map.new(data.extra.by_cwd, fn {cwd, sessions} ->
        {cwd, Enum.reject(sessions, &(&1 == session))}
      end)

    {:keep_state, %{data | extra: %{by_cwd: by_cwd}}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:sessions, cwd}, _state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, Map.get(data.extra.by_cwd, cwd, [])}}]}
  end

  def handle_event({:call, from}, {:peers, session}, _state, data) do
    cwd =
      Enum.find_value(data.extra.by_cwd, fn {cwd, sessions} ->
        if session in sessions, do: cwd
      end)

    peers =
      case cwd do
        nil -> []
        _ -> data.extra.by_cwd |> Map.get(cwd, []) |> Enum.reject(&(&1 == session))
      end

    {:keep_state_and_data, [{:reply, from, {:ok, peers}}]}
  end

  def handle_event({:call, from}, {:relay, from_session, to, content}, _state, data) do
    same_workspace? =
      Enum.any?(data.extra.by_cwd, fn {_cwd, sessions} ->
        from_session in sessions and to in sessions
      end)

    result =
      if same_workspace? do
        DshBeam.Session.append(to, %{
          "role" => "peer_message",
          "from" => inspect(from_session),
          "content" => content
        })
      else
        {:error, :different_workspace}
      end

    {:keep_state_and_data, [{:reply, from, result}]}
  end
end
