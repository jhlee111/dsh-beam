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
