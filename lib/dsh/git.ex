defmodule DshBeam.Git do
  @moduledoc """
  A thin git helper over `git`(1) — the mechanism behind workspace/session
  isolation. Each session checks out its own `git worktree`, so two sessions
  over one repository never share a working directory and cannot clobber each
  other's files.

  This module is a capability, not a plugin: it runs `git` directly (via
  System.cmd) so the workspace layer does not depend on the Shell plugin's
  fiber. It is deliberately narrow — worktree add/remove/list, branch, and
  repo/root detection — the vocabulary a workspace needs.
  """

  # L2: a checkout younger than the grace period is a live session by
  # definition — merge state is irrelevant. Default 24h: boot GCs (even
  # concurrent ones on other repos) cannot sweep worktrees created today.
  @default_grace_seconds 24 * 60 * 60

  @doc "True when `dir` is inside a git working tree (git rev-parse succeeds)."
  def repo_root(dir) do
    case git(dir, ["rev-parse", "--show-toplevel"]) do
      {:ok, root} -> {:ok, String.trim(root)}
      {:error, _status, _output} -> :error
    end
  end

  @doc "Create a worktree for `branch` under `dest` (branch created if absent)."
  def worktree_add(repo, branch, dest) do
    case git(repo, ["worktree", "add", "-b", branch, dest]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, status, output} -> {:error, {:worktree_add, status, String.trim(output)}}
    end
  end

  @doc "Remove a worktree at `dest` (force, in case of dirty state)."
  def worktree_remove(repo, dest) do
    case git(repo, ["worktree", "remove", "--force", dest]) do
      {:ok, _} -> :ok
      {:error, status, output} -> {:error, {:worktree_remove, status, String.trim(output)}}
    end
  end

  @doc "The branch checked out in the worktree at `dest`."
  def branch(dest) do
    case git(dest, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} -> {:ok, String.trim(branch)}
      {:error, status, output} -> {:error, {:branch, status, String.trim(output)}}
    end
  end

  @doc "List worktrees as a flat string (git worktree list --porcelain)."
  def worktree_list(repo) do
    case git(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, output} -> {:ok, output}
      {:error, status, output} -> {:error, {:worktree_list, status, String.trim(output)}}
    end
  end

  @doc """
  Garbage-collect stale session worktrees — conservatively.

  A worktree is swept only when ALL hold:

    - branch is `session/*` AND merged into the default branch,
    - path not in `opts[:keep]` (default: the caller's cwd),
    - checkout older than `opts[:grace_seconds]` (default 24h) — a worktree
      created moments ago is a live session by definition,
    - no live marker (`<path>/.dsh/live` — written by
      `DshBeam.Workspace.open_session`, removed by `close_session`),
    - `git worktree remove` WITHOUT `--force` accepts it — git itself refuses
      any tree with modified/untracked files, so a dirty session survives.

  Never `--force`: git's refusal is the last line of defense. Removal is
  best-effort per worktree. Returns `{:ok, removed}` with the removed paths.
  """
  def prune_merged_worktrees(repo, opts \\ []) do
    keep = opts |> Keyword.get(:keep, [File.cwd!()]) |> Enum.map(&canonical/1)
    grace = Keyword.get(opts, :grace_seconds, @default_grace_seconds)
    default = default_branch(repo)
    now = System.os_time(:second)

    with {:ok, worktrees} <- worktree_list_parsed(repo) do
      removed =
        Enum.reduce(worktrees, [], fn wt, acc ->
          if merged_session_worktree?(wt, keep, repo, default, now, grace) do
            # L1: never --force. git refuses a tree with modified/untracked
            # files, and a gitignored-only tree is indistinguishable from a
            # clean one (see clean_worktree?/1) — so the non-forced call is
            # the only place git's own dirty-tree safety can bite.
            case git(repo, ["worktree", "remove", wt.path]) do
              {:ok, _} ->
                _ = delete_branch(repo, wt.branch)
                [wt.path | acc]

              {:error, _status, _output} ->
                acc
            end
          else
            acc
          end
        end)

      _ = prune(repo)
      {:ok, Enum.reverse(removed)}
    end
  end

  defp merged_session_worktree?(%{path: path, branch: branch}, keep, repo, default, now, grace) do
    is_binary(branch) and
      String.starts_with?(branch, "session/") and
      canonical(path) not in keep and
      is_binary(default) and
      merged?(repo, branch, default) and
      worktree_age_ok?(path, now, grace) and
      not live_worktree?(path) and
      clean_worktree?(path)
  end

  # L2: a checkout younger than the grace period is a live session by
  # definition — merge state is irrelevant. Uses the checkout's mtime as the
  # creation time proxy; a boot GC that runs moments after a worktree was
  # created therefore protects it.
  defp worktree_age_ok?(path, now, grace) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> now - mtime >= grace
      _ -> false
    end
  end

  # L3: an agent pins its session by writing <path>/.dsh/live; the workspace
  # writes it when the worktree is checked out and removes it on close. A
  # marker means "a live agent owns this checkout" — never swept.
  defp live_worktree?(path), do: File.exists?(Path.join([path, ".dsh", "live"]))

  # Data safety: "merged into the default branch" does NOT mean the checkout
  # has no work left. A worktree with uncommitted changes is treated as live —
  # boot GC must never delete someone's in-progress files.
  #
  # `--ignored` is deliberate (flaw #3): `.dsh/` — the agent's session logs and
  # scripts — is gitignored, so plain `status --porcelain` reports a worktree
  # whose only local artifacts are in `.dsh/` as clean, and git (without
  # --force) would remove it. `--ignored` surfaces `.dsh/` as `!! .dsh/`, so
  # such a tree is treated as non-clean and survives. A dead session is only
  # swept when its checkout has NO local artifacts at all — conservative by
  # design.
  defp clean_worktree?(path) do
    case git(path, ["status", "--porcelain", "--ignored"]) do
      {:ok, output} -> String.trim(output) == ""
      _ -> false
    end
  end

  # git worktree list returns canonical paths (/private/var/... on macOS while
  # File.cwd!/tmp may be /var/...); resolve the full symlink chain (component
  # by component, /var -> private/var) so keep-path matching is
  # path-independent.
  defp canonical(path) do
    path
    |> Path.expand()
    |> String.split("/", trim: true)
    |> Enum.reduce("/", fn component, acc ->
      case :file.read_link_all(Path.join(acc, component)) do
        {:ok, target} -> Path.join(acc, to_string(target))
        _ -> Path.join(acc, component)
      end
    end)
  end

  # -- worktree GC helpers --

  @doc false
  # Parse `git worktree list --porcelain` into %{path, branch} records.
  # Detached worktrees (no "branch" line) yield branch: nil.
  def worktree_list_parsed(repo) do
    with {:ok, output} <- worktree_list(repo) do
      worktrees =
        output
        |> String.split("
")
        |> Enum.chunk_by(&(&1 == ""))
        |> Enum.reject(&(&1 == [""]))
        |> Enum.map(fn block ->
          path =
            block |> Enum.find(&String.starts_with?(&1, "worktree ")) |> strip_prefix("worktree ")

          branch =
            block
            |> Enum.find(&String.starts_with?(&1, "branch "))
            |> strip_prefix("branch refs/heads/")

          %{path: path, branch: branch}
        end)
        |> Enum.reject(&is_nil(&1.path))

      {:ok, worktrees}
    end
  end

  @doc false
  # The default branch for merge checks: origin's HEAD symbolic ref first
  # (the repo's canonical default), then master/main by presence.
  def default_branch(repo) do
    case git(repo, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) do
      {:ok, ref} ->
        String.trim(ref)

      {:error, _, _} ->
        cond do
          branch_exists?(repo, "master") -> "master"
          branch_exists?(repo, "main") -> "main"
          true -> nil
        end
    end
  end

  @doc false
  # True when `branch` is an ancestor of `default` (all its commits are in).
  def merged?(repo, branch, default) do
    case git(repo, ["merge-base", "--is-ancestor", branch, default]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc false
  # Safe local-branch delete: fails (and is skipped) when the branch holds
  # commits not reachable from its upstream — exactly what we want to keep.
  def delete_branch(repo, branch) do
    case git(repo, ["branch", "-d", branch]) do
      {:ok, _} -> :ok
      {:error, _, _} -> {:error, :not_fully_merged}
    end
  end

  @doc false
  # Drop stale worktree bookkeeping (.git/worktrees entries for removed dirs).
  def prune(repo) do
    case git(repo, ["worktree", "prune"]) do
      {:ok, _} -> :ok
      {:error, _, _} -> :ok
    end
  end

  defp branch_exists?(repo, branch) do
    match?({:ok, _}, git(repo, ["rev-parse", "--verify", "--quiet", branch]))
  end

  defp strip_prefix(nil, _prefix), do: nil
  defp strip_prefix(line, prefix), do: String.replace_prefix(line, prefix, "")

  defp git(dir, args) do
    # System.cmd links its subprocess port to the caller; a caller that traps
    # exits (a plugin fiber) would receive the port's completion EXIT and stop.
    # Run it in an unlinked, monitored process and have it report the result
    # back — the same isolation the Shell plugin uses for its subprocess.
    parent = self()

    pid =
      spawn(fn ->
        send(
          parent,
          {:git_result, self(), System.cmd("git", args, stderr_to_stdout: true, cd: dir)}
        )
      end)

    ref = Process.monitor(pid)

    receive do
      {:git_result, ^pid, {output, status}} ->
        Process.demonitor(ref, [:flush])
        if status == 0, do: {:ok, output}, else: {:error, status, output}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :crashed, ""}
    end
  end
end
