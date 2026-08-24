defmodule DshBeam.CrashAudit.Plugin do
  @moduledoc """
  Exposes the crash audit log as a plugin capability, so other plugins can
  read or subscribe to the crash trail through the composition instead of
  reaching for a global path.

  Provides `:crash_audit` — the audit GenServer owned by the runtime. The
  runtime injects the audit pid into every entry's config (`:audit`), so this
  plugin does not have to call back into the runtime at mount time (that
  would deadlock: the runtime is busy applying the composition). When the
  runtime was started without an `:audit_path` the provided value is `nil`
  (the audit is opt-in).

  Read it with `DshBeam.CrashAudit.all/1` or live-subscribe with
  `DshBeam.CrashAudit.subscribe/1`.
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    audit = Keyword.get(opts, :audit)
    {:ok, [], %{crash_audit: audit}, %{audit: audit}}
  end
end
