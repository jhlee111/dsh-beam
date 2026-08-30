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

  A session may also carry its OWN extra folders (`get_session_folders/2` /
  `set_session_folders/3`): a per-session allowlist of related repos/folders
  the agent may read — and, when marked writable, write — alongside the
  session root. These persist with the roster manifest, so a restart re-opens
  them. `open_session/3` with `worktree: false` forces an in-place session
  even over a git repository (the UI's "no worktree" option).

  Sessions sharing a `cwd` "know" each other (the same working directory is the
  workspace): `peers/2` returns every other session there, and `relay/3` appends
  a peer message to the target session's log — the minimal port of the reference
  `agent-team` peer mailbox.

  ## Boot GC is OPT-IN

  `mount/2` never prunes on its own. Only a mount configured with
  `boot_prune: true` **and** an explicit `repo:` (the repository to sweep)
  runs `DshBeam.Git.prune_merged_worktrees/2` — never a `File.cwd!()`
  guess. A bare `mix test` or a console started from an unrelated directory
  must not be able to delete another session's worktree.
  """

  use DshBeam.Plugin

  setting(:default_root,
    type: :string,
    default: ".",
    doc: "The default directory new sessions are opened over"
  )

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    # Boot GC is OPT-IN (L4): only a mount that explicitly asks for it — with
    # an explicit repo, never a File.cwd!() guess — may sweep. The sweep is
    # best-effort, keeps the caller's cwd, and swallows failures: it must
    # never block the composition from mounting, and it must never delete a
    # worktree git itself (without --force) would refuse to remove.
    if Keyword.get(opts, :boot_prune, false) do
      case Keyword.get(opts, :repo) do
        nil ->
          # no explicit repo: refuse to guess from cwd — a wrong guess is how
          # a test suite or console GC'd a live session's worktree
          :ok

        repo ->
          keep = [File.cwd!() | Keyword.get(opts, :keep, [])]
          _ = DshBeam.Git.prune_merged_worktrees(repo, keep: keep)
          :ok
      end
    end

    roster_path = Keyword.get(opts, :roster_path)

    {:ok, [], %{workspace: self()}, restore_roster(roster_path)}
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
  `session/<id>` worktree, and starts the session log in that checkout (a
  durable JSONL under `<cwd>/.dsh/session.jsonl`, via `DshBeam.Session.File`).
  When the workspace is mounted with `:roster_path`, each open/close persists
  the roster manifest there so a restart re-opens the same sessions. Returns
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

  @doc "Persist the roster manifest now (e.g. after a session rename)."
  def persist(workspace) when is_pid(workspace) do
    :gen_statem.call(workspace, :persist_roster)
  end

  @doc "The session's own extra folders: a list of %{path, writable}."
  def get_session_folders(workspace, session) when is_pid(workspace) and is_pid(session) do
    :gen_statem.call(workspace, {:get_session_folders, session})
  end

  @doc "Replace the session's extra folders (persisted with the roster)."
  def set_session_folders(workspace, session, folders)
      when is_pid(workspace) and is_pid(session) and is_list(folders) do
    :gen_statem.call(workspace, {:set_session_folders, session, folders})
  end

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
          extra = register(data.extra, session, meta.cwd, meta.repo, meta.file)
          persist_roster(extra)
          %{data | extra: extra}

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
        # Stop the session first so no more appends land in its log, then tear
        # down. A worktree-backed session owns a checkout to remove; an
        # in-place one does not. Never let a git failure stop the teardown.
        if Process.alive?(session), do: Process.exit(session, :shutdown)

        if repo do
          # Drop the whole `.dsh` dir — the live marker AND the session log —
          # before removing the checkout: `git worktree remove` refuses a
          # worktree with untracked residue.
          _ = File.rm_rf(Path.join(cwd, ".dsh"))
          DshBeam.Git.worktree_remove(repo, cwd)
        end

        extra = unregister_session(data.extra, session)
        persist_roster(extra)
        {:keep_state, %{data | extra: extra}, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, :all_sessions, _state, data) do
    sessions =
      Map.new(data.extra.sessions, fn {session, %{cwd: cwd, repo: repo}} ->
        folders = data.extra.sessions |> Map.get(session, %{}) |> Map.get(:folders, [])
        {session, %{cwd: cwd, repo: repo, title: session_title(session), folders: folders}}
      end)

    {:keep_state_and_data, [{:reply, from, sessions}]}
  end

  def handle_event({:call, from}, :persist_roster, _state, data) do
    persist_roster(data.extra)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:get_session_folders, session}, _state, data) do
    folders = Map.get(data.extra.sessions, session, %{}) |> Map.get(:folders, [])
    {:keep_state_and_data, [{:reply, from, {:ok, folders}}]}
  end

  def handle_event({:call, from}, {:set_session_folders, session, folders}, _state, data) do
    case Map.get(data.extra.sessions, session) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :unknown_session}}]}

      meta ->
        meta = Map.put(meta, :folders, folders)
        sessions = Map.put(data.extra.sessions, session, meta)
        data = %{data | extra: %{data.extra | sessions: sessions}}
        persist_roster(data.extra)
        {:keep_state, data, [{:reply, from, :ok}]}
    end
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
  defp default_title(dir, opts) do
    if Keyword.get(opts, :worktree, true) == false, do: nil, else: Path.basename(dir)
  end

  defp open(dir, opts) do
    dir = Path.expand(dir)
    # A worktree session defaults its title to the repo basename (the
    # reference's "session over <repo>"); an in-place session (worktree:
    # false) keeps nil so the sidebar shows "Session <pid>" until renamed.
    title = Keyword.get(opts, :title) || default_title(dir, opts)

    # The UI's "no worktree" option: force an in-place session even over a git
    # repository (the session stays rooted at the folder itself).
    if Keyword.get(opts, :worktree, true) == false do
      in_place_session(dir, title)
    else
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
  end

  defp try_worktree(root, branch, dest, title) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _} <- DshBeam.Git.worktree_add(root, branch, dest) do
      case start_live_session(dest, title) do
        {:ok, session, file} ->
          {:ok, session, %{cwd: dest, repo: root, file: file}}

        {:error, _} = err ->
          # never leak a checkout whose session could not start: tear it down
          # (the branch is a fresh session/* branch, so a non-forced remove
          # succeeds — a failed start leaves nothing dirty)
          _ = DshBeam.Git.worktree_remove(root, dest)
          err
      end
    end
  end

  defp start_live_session(dest, title) do
    with :ok <- mark_live(dest),
         {:ok, session, file} <- start_session(dest, title) do
      {:ok, session, file}
    end
  end

  # L3: pin this checkout as a live agent session. Written immediately after
  # the worktree is created — before any concurrent boot GC could see it —
  # and removed by close_session/2. A marked worktree is never swept.
  defp mark_live(dest) do
    with :ok <- File.mkdir_p(Path.join(dest, ".dsh")),
         :ok <- File.write(Path.join([dest, ".dsh", "live"]), "live\n") do
      :ok
    end
  end

  defp in_place_session(dir, title) do
    case start_session(dir, title) do
      {:ok, session, file} -> {:ok, session, %{cwd: dir, repo: nil, file: file}}
      other -> other
    end
  end

  defp default_dest(repo_root, branch) do
    base = Path.basename(repo_root)
    Path.join([Path.dirname(repo_root), base <> "-worktrees", branch])
  end

  # The durable session log lives next to the `.dsh/live` marker, inside the
  # session's checkout (or the in-place folder). Each session gets a unique
  # file so two in-place sessions over the same folder never share a log.
  defp start_session(cwd, title) do
    file = Path.join([cwd, ".dsh", "session-#{System.unique_integer([:positive])}.jsonl"])

    with :ok <- File.mkdir_p(Path.join(cwd, ".dsh")) do
      case DshBeam.Session.File.start(path: file, title: title, cwd: cwd) do
        {:ok, session} -> {:ok, session, file}
        other -> other
      end
    end
  end

  # -- roster persistence (opt-in via :roster_path) --

  defp restore_roster(nil), do: %{by_cwd: %{}, sessions: %{}, roster_path: nil}

  defp restore_roster(roster_path) do
    extra = %{by_cwd: %{}, sessions: %{}, roster_path: roster_path}

    Enum.reduce(read_roster(roster_path), extra, fn entry, acc ->
      case entry do
        %{"cwd" => cwd, "repo" => repo, "title" => title, "file" => file} = entry ->
          folders = Map.get(entry, "folders", [])
          case DshBeam.Session.File.start(path: file, title: title, cwd: cwd) do
            {:ok, session} -> acc |> register(session, cwd, repo, file) |> put_folders(session, folders)
            {:error, _} -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp persist_roster(%{roster_path: nil}), do: :ok

  defp persist_roster(%{roster_path: path, sessions: sessions}) do
    entries =
      Enum.map(sessions, fn {session, %{cwd: cwd, repo: repo, file: file}} ->
        folders = sessions |> Map.get(session, %{}) |> Map.get(:folders, [])
        %{"cwd" => cwd, "repo" => repo, "title" => session_title(session), "file" => file, "folders" => folders}
      end)

    File.mkdir_p(Path.dirname(path))
    File.write(path, JSON.encode!(entries))
  end

  defp read_roster(path) do
    if File.exists?(path) do
      case JSON.decode(File.read!(path)) do
        {:ok, entries} when is_list(entries) -> entries
        _ -> []
      end
    else
      []
    end
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

  defp register(extra, session, cwd, repo, file \\ nil) do
    by_cwd = Map.update(extra.by_cwd, cwd, [session], fn sessions -> [session | sessions] end)
    sessions = Map.put(extra.sessions, session, %{cwd: cwd, repo: repo, file: file})
    %{extra | by_cwd: by_cwd, sessions: sessions}
  end

  defp put_folders(extra, session, folders) do
    sessions =
      case Map.get(extra.sessions, session) do
        nil -> extra.sessions
        meta -> Map.put(extra.sessions, session, Map.put(meta, :folders, folders))
      end

    %{extra | sessions: sessions}
  end

  defp unregister_session(extra, session) do
    sessions = Map.delete(extra.sessions, session)

    by_cwd =
      Map.new(extra.by_cwd, fn {cwd, list} -> {cwd, Enum.reject(list, &(&1 == session))} end)

    %{extra | by_cwd: by_cwd, sessions: sessions}
  end
end
