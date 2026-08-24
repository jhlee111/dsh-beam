defmodule DshBeam.CrashAudit.Plugin do
  @moduledoc """
  Exposes the crash audit log as a plugin capability, so other plugins can
  read or subscribe to the crash trail through the composition instead of
  reaching for a global path.

  Provides `:crash_audit` — the audit GenServer owned by the runtime (the
  runtime resolves it from the `:runtime` config every entry receives, so no
  audit pid has to be threaded through the entries). Read it with
  `DshBeam.CrashAudit.all/1` or live-subscribe with
  `DshBeam.CrashAudit.subscribe/1`. When the runtime was started without an
  `:audit_path` the provided value is `nil` (the audit is opt-in).
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(ctx, opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    audit = DshBeam.Runtime.audit(runtime)
    {:ok, [], %{crash_audit: audit}, %{audit: audit, ctx: ctx}}
  end
end
