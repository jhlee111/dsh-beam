# Credo, scoped to bug-catching checks only. Elixir 1.18+'s built-in type
# checker (mix compile --warnings-as-errors) already reports undefined
# functions and unused defs, so Credo is enabled only for the checks below —
# things that statically flag likely mistakes and debug leftovers.
#
# Using `checks: %{enabled: [...]}` (a map, not a list) REPLACES Credo's default
# check set; a list would merge with it and re-enable the style checks we are
# deliberately skipping.

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "scripts/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/priv/static/"]
      },
      checks: %{
        enabled: [
          # ---- consistency: format is already enforced by mix format ----
          {Credo.Check.Consistency.ExceptionNames, []},

          # ---- warning: the bug-catching subset (the reason Credo is here) ----
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},

          # ---- design: tag hygiene (no stale TODO/FIXME drifting) ----
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Design.TagTODO, [exit_status: 2]}
        ]
      }
    }
  ]
}
