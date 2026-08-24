defmodule DshBeam.Workspace do
  @moduledoc """
  The workspace capability: owns the sessions over a directory and lets a
  session address its peers.

  A workspace groups sessions by their working directory. Opening a session
  over a git repository checks out a fresh `git worktree` (a per-session
  checkout on a `session/<id>` branch), so two sessions over one repository
  never share a working directory and cannot clobber each other's files. A
  folder that is not a git repository — or a repository whose worktree cannot
  be created (e.g. permissions) — opens in-place instead, rooted at the folder
  itself, because working from any folder is part of the harness. `close_session`
  tears down the worktree when one was created.

  Sessions sharing a `cwd` "know" each other (the same working directory is the
  workspace): `peers/2` returns every other session there, and `relay/3` appends
  a peer message to the target session's log — the minimal port of the reference
  `agent-team` peer mailbox.
  """

  use DshBeam.Plugin

  setting(:default_root,
    type: :string,
    default: ".",
    doc: "The default directory new sessions are opened over"
  )

  @impl DshBeam.Plugin
  def mount(_ctx, _opts) do
    {:ok, [], %{workspace: self()}, %{by_cwd: %{}, sessions: %{}}}
  end

  @impl DshBeam.Plugin
  def handle_dsh_ready(state) do
    # The workspace owns its sessions: a release inverse stops every one of
    # them when the workspace withdraws (after dependents drained). The
    # worktrees themselves are left on disk — they are §6.1 "outside the
    # boundary" and dropping them would destroy session work on a restart.
    sessions = Map.keys(state.extra.sessions)

    :ok =
      DshBeam.Context.effect(state.ctx, fn st ->
        Enum.each(sessions, fn session ->
          if Process.alive?(session), do: Process.exit(session, :shutdown)
        end)

        st
      end)

    {:ok, state}
  end

  # -- session lifecycle (worktree-backed) --

  @doc """
  Open a session over `repo`: resolves the repository root, checks out a fresh
  `session/<id>` worktree, and starts the session log in that checkout. Returns
  `{:ok, session}` — the session handle to pass to close/relay.
  """
  def open_session(workspace, repo, opts \\ []) when is_pid(workspace) and is_binary(repo) do
    :gen_statem.call(workspace, {:open_session, repo, opts})
  end

  @doc "Close a session: remove its worktree, stop its log, drop it from the roster."
  def close_session(workspace, session) when is_pid(workspace) and is_pid(session) do
    :gen_statem.call(workspace, {:close_session, session})
  end

  @doc "Every session in the roster: a map of session => %{cwd, repo, title}."
  def all_sessions(workspace) when is_pid(workspace) do
    :gen_statem.call(workspace, :all_sessions)
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
  def handle_event({:call, from}, {:open_session, repo, opts}, _state, data) do
    result = open(repo, opts)

    data =
      case result do
        {:ok, session, meta} ->
          %{data | extra: register(data.extra, session, meta.cwd, meta.repo)}

        _ ->
          data
      end

    reply =
      case result do
        {:ok, session, _meta} -> {:ok, session}
        other -> other
      end

    {:keep_state, data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, {:close_session, session}, _state, data) do
    case Map.get(data.extra.sessions, session) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :unknown_session}}]}

      %{cwd: cwd, repo: repo} ->
        # a worktree-backed session owns a checkout to remove; an in-place one
        # does not. Never let a git failure stop the session teardown.
        if repo, do: DshBeam.Git.worktree_remove(repo, cwd)

        if Process.alive?(session), do: Process.exit(session, :shutdown)
        data = %{data | extra: unregister_session(data.extra, session)}
        {:keep_state, data, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, :all_sessions, _state, data) do
    sessions =
      Map.new(data.extra.sessions, fn {session, %{cwd: cwd, repo: repo}} ->
        {session, %{cwd: cwd, repo: repo, title: session_title(session)}}
      end)

    {:keep_state_and_data, [{:reply, from, sessions}]}
  end

  def handle_event({:call, from}, {:register, session, cwd}, _state, data) do
    data = %{data | extra: register(data.extra, session, cwd, nil)}
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:unregister, session}, _state, data) do
    data = %{data | extra: unregister_session(data.extra, session)}
    {:keep_state, data, [{:reply, from, :ok}]}
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

  # -- internals --

  # Open a session over `dir`: a git worktree checkout when the folder lives
  # inside a repository AND the checkout succeeds; otherwise an in-place
  # session rooted at the folder itself. Working from any folder — not only a
  # git repo — is part of the harness, so a non-repo (or a repo whose worktree
  # cannot be created, e.g. permissions) degrades to in-place rather than
  # refusing.
  defp open(dir, opts) do
    dir = Path.expand(dir)
    title = Keyword.get(opts, :title) || Path.basename(dir)

    case DshBeam.Git.repo_root(dir) do
      {:ok, root} ->
        branch = Keyword.get(opts, :branch, "session/#{System.unique_integer([:positive])}")
        dest = Keyword.get(opts, :dest, default_dest(root, branch))

        case try_worktree(root, branch, dest, title) do
          {:ok, session, meta} -> {:ok, session, meta}
          {:error, _reason} -> in_place_session(dir, title)
        end

      :error ->
        in_place_session(dir, title)
    end
  end

  defp try_worktree(root, branch, dest, title) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _} <- DshBeam.Git.worktree_add(root, branch, dest),
         {:ok, session} <- DshBeam.Session.Memory.start(title: title, cwd: dest) do
      {:ok, session, %{cwd: dest, repo: root}}
    end
  end

  defp in_place_session(dir, title) do
    case DshBeam.Session.Memory.start(title: title, cwd: dir) do
      {:ok, session} -> {:ok, session, %{cwd: dir, repo: nil}}
      other -> other
    end
  end

  defp default_dest(repo_root, branch) do
    base = Path.basename(repo_root)
    Path.join([Path.dirname(repo_root), base <> "-worktrees", branch])
  end

  defp session_title(session) do
    try do
      if Process.alive?(session) do
        case DshBeam.Session.header(session) do
          %{title: title} -> title
          _ -> nil
        end
      end
    catch
      :exit, _ -> nil
    end
  end

  defp register(extra, session, cwd, repo) do
    by_cwd = Map.update(extra.by_cwd, cwd, [session], fn sessions -> [session | sessions] end)
    sessions = Map.put(extra.sessions, session, %{cwd: cwd, repo: repo})
    %{extra | by_cwd: by_cwd, sessions: sessions}
  end

  defp unregister_session(extra, session) do
    sessions = Map.delete(extra.sessions, session)

    by_cwd =
      Map.new(extra.by_cwd, fn {cwd, list} -> {cwd, Enum.reject(list, &(&1 == session))} end)

    %{extra | by_cwd: by_cwd, sessions: sessions}
  end
end
