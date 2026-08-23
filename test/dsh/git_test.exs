defmodule DshBeam.GitTest do
  use ExUnit.Case, async: false

  # Each test spins up a real throwaway git repo in tmp, so worktree behavior is
  # exercised against git(1) rather than mocked.

  setup :git_repo

  defp git_repo(_context) do
    dir = Path.join(System.tmp_dir!(), "dsh_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    run_git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "hello")
    run_git(dir, ["add", "."])
    run_git(dir, ["commit", "-q", "-m", "init"])

    on_exit(fn -> File.rm_rf!(dir) end)
    %{repo: dir}
  end

  test "repo_root returns the repository top level", %{repo: repo} do
    assert {:ok, root} = DshBeam.Git.repo_root(repo)

    # compare by effect, not by path string: the returned root is the directory
    # that contains .git (git rev-parse already returns a canonical path)
    assert File.exists?(Path.join(root, ".git"))
  end

  test "repo_root is :error outside any repository" do
    outside = Path.join(System.tmp_dir!(), "dsh_not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert DshBeam.Git.repo_root(outside) == :error
  end

  test "worktree_add creates an isolated checkout with its own branch", %{repo: repo} do
    dest = Path.join(System.tmp_dir!(), "dsh_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dest) end)

    assert {:ok, _} = DshBeam.Git.worktree_add(repo, "session/abc", dest)
    assert {:ok, "session/abc"} = DshBeam.Git.branch(dest)
    assert File.exists?(Path.join(dest, "README.md"))
  end

  test "worktree_remove removes the checkout", %{repo: repo} do
    dest = Path.join(System.tmp_dir!(), "dsh_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dest) end)

    assert {:ok, _} = DshBeam.Git.worktree_add(repo, "session/rm", dest)
    assert :ok = DshBeam.Git.worktree_remove(repo, dest)
    refute File.exists?(dest)
  end

  defp run_git(dir, args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true, cd: dir)
    out
  end
end
