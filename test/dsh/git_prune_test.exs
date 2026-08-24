defmodule DshBeam.GitPruneTest do
  use ExUnit.Case, async: false

  # Exercises the boot-time worktree GC against a real throwaway repo:
  # a merged session worktree is swept, a live (unmerged) one and the
  # keep-path are left alone.

  setup :git_repo

  defp git_repo(_context) do
    dir = Path.join(System.tmp_dir!(), "dsh_prune_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    run_git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "hello")
    run_git(dir, ["add", "."])
    run_git(dir, ["commit", "-q", "-m", "init"])

    on_exit(fn -> File.rm_rf!(dir) end)
    %{repo: dir}
  end

  defp session_worktree(repo, branch) do
    dest =
      Path.join(
        System.tmp_dir!(),
        "dsh_prune_wt_#{branch}_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _} = DshBeam.Git.worktree_add(repo, branch, dest)
    on_exit(fn -> File.rm_rf!(dest) end)
    dest
  end

  test "a session worktree whose branch is merged into the default is swept" do
    # set up: repo + a merged session worktree (its branch is an ancestor of
    # main because it was created at the initial commit)
    %{repo: repo} = session_context()
    dest = session_worktree(repo, "session/merged")
    # branch == initial commit == ancestor of main -> merged
    assert File.exists?(dest)

    assert {:ok, [_removed]} = DshBeam.Git.prune_merged_worktrees(repo, keep: [])
    # git reports canonical paths (/private/var vs /var) — compare by effect
    refute File.exists?(dest)

    # the local branch is deleted too (it was fully merged)
    assert {:error, _} = run_git_result(repo, ["rev-parse", "--verify", "session/merged"])
  end

  test "a live (unmerged) session worktree is kept" do
    %{repo: repo} = session_context()

    # make the session branch actually diverge from main (unmerged)
    dest = session_worktree(repo, "session/live")
    File.write!(Path.join(dest, "new.txt"), "wip")
    run_git(dest, ["add", "."])
    run_git(dest, ["commit", "-q", "-m", "wip"])
    assert File.exists?(dest)

    assert {:ok, []} = DshBeam.Git.prune_merged_worktrees(repo, keep: [])
    assert File.exists?(dest)
    assert {:ok, "session/live"} = DshBeam.Git.branch(dest)
  end

  test "the keep path is never removed even when merged" do
    %{repo: repo} = session_context()
    dest = session_worktree(repo, "session/keepme")

    assert {:ok, []} = DshBeam.Git.prune_merged_worktrees(repo, keep: [dest])
    assert File.exists?(dest)
  end

  test "a merged session worktree with uncommitted changes is kept (data safety)" do
    %{repo: repo} = session_context()
    dest = session_worktree(repo, "session/dirty")
    # merged (created at initial commit) but dirty: boot GC must NOT delete it
    File.write!(Path.join(dest, "wip.txt"), "in progress")

    assert {:ok, []} = DshBeam.Git.prune_merged_worktrees(repo, keep: [])
    assert File.exists?(dest)
    assert File.read!(Path.join(dest, "wip.txt")) == "in progress"
  end

  test "non-session branches are never swept" do
    %{repo: repo} = session_context()
    dest = Path.join(System.tmp_dir!(), "dsh_prune_other_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dest) end)
    assert {:ok, _} = DshBeam.Git.worktree_add(repo, "feature/x", dest)
    assert File.exists?(dest)

    assert {:ok, []} = DshBeam.Git.prune_merged_worktrees(repo, keep: [])
    assert File.exists?(dest)
  end

  # A fresh repo with an origin HEAD pointing at main, so default_branch/1
  # resolves without relying on local branch guessing.
  defp session_context do
    dir = Path.join(System.tmp_dir!(), "dsh_prune_ctx_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    run_git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "hello")
    run_git(dir, ["add", "."])
    run_git(dir, ["commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf!(dir) end)
    %{repo: dir}
  end

  defp run_git(dir, args) do
    git = ["-c", "user.name=CI", "-c", "user.email=ci@example.com" | args]
    {out, 0} = System.cmd("git", git, stderr_to_stdout: true, cd: dir)
    out
  end

  defp run_git_result(dir, args) do
    git = ["-c", "user.name=CI", "-c", "user.email=ci@example.com" | args]
    {_out, status} = System.cmd("git", git, stderr_to_stdout: true, cd: dir)
    if status == 0, do: {:ok, status}, else: {:error, status}
  end
end
