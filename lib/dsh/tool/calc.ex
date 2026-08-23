defmodule DshBeam.Tool.Calc do
  @moduledoc """
  The calculator tool — a stateless arithmetic plugin (a tool is a plugin).

  Exposes the `calc` tool to the agent loop: evaluate a safe arithmetic
  expression with `+ - * / % ^` and parentheses, respecting operator
  precedence. No dependencies, so it activates as soon as it is mounted and
  never blocks on other fibers.

  The evaluator is a small Pratt parser, deliberately not `Code.eval_string`:
  a tool that can execute arbitrary Elixir is exactly the capability boundary
  the harness keeps behind the shell tool. This plugin only parses numbers,
  operators, and parentheses — nothing else.
  """

  use DshBeam.Plugin

  tool(:calc,
    description:
      "Evaluate a safe arithmetic expression (numbers, + - * / % ^, parentheses) and return the result",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "expression" => %{
          "type" => "string",
          "description" => "e.g. \"(1 + 2) * 3\""
        }
      },
      "required" => ["expression"]
    }
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:calc, %{"expression" => expression}, _state)
      when is_binary(expression) do
    case evaluate(expression) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_dsh_tool_call(:calc, _args, _state), do: {:error, :expression_must_be_a_string}

  @doc "Evaluate a safe arithmetic expression. Returns {:ok, number} or {:error, reason}."
  def evaluate(expression) when is_binary(expression) do
    with {:ok, tokens} <- tokenize(expression),
         {:ok, ast} <- parse(tokens) do
      {:ok, ast}
    end
  end

  # -- tokenizer --

  @operators %{
    "+" => {:op, :add},
    "-" => {:op, :sub},
    "*" => {:op, :mul},
    "/" => {:op, :div},
    "%" => {:op, :mod},
    "^" => {:op, :pow}
  }

  defp tokenize(expression) do
    expression
    |> String.replace(" ", "")
    |> String.to_charlist()
    |> do_tokenize([], [])
    |> case do
      {:ok, tokens} ->
        if tokens == [] do
          {:error, :empty_expression}
        else
          {:ok, tokens}
        end

      other ->
        other
    end
  end

  # accumulate digits, then flush at a boundary
  defp do_tokenize([], acc, tokens) do
    {:ok, Enum.reverse(flush_number(acc, tokens))}
  end

  defp do_tokenize([c | rest], acc, tokens) do
    cond do
      c in ?0..?9 or c == ?. ->
        do_tokenize(rest, [c | acc], tokens)

      true ->
        tokens = flush_number(acc, tokens)

        case Map.fetch(@operators, <<c>>) do
          {:ok, token} -> do_tokenize(rest, [], [token | tokens])
          :error -> {:error, {:unexpected_character, <<c>>}}
        end
    end
  end

  defp flush_number([], tokens), do: tokens

  defp flush_number(digits, tokens) do
    case Float.parse(digits |> Enum.reverse() |> List.to_string()) do
      {number, ""} -> [{:num, number} | tokens]
      _ -> raise "unreachable: validated by the digit-accumulator"
    end
  end

  # -- parser (Pratt) --

  # precedence (lower binds looser): ^ (right assoc) > unary - > * / % > + -
  @prec %{
    add: 1,
    sub: 1,
    mul: 2,
    div: 2,
    mod: 2,
    pow: 3
  }

  defp parse(tokens) do
    with {:ok, ast, rest} <- parse_expr(tokens, 0) do
      case rest do
        [] -> {:ok, ast}
        [{:op, op} | _] -> {:error, {:missing_right_operand, op}}
        [token | _] -> {:error, {:unexpected_token, token}}
      end
    end
  end

  # expression := unary (op unary)*, with precedence climbing
  defp parse_expr(tokens, min_prec) do
    with {:ok, lhs, tokens} <- parse_unary(tokens) do
      climb(lhs, tokens, min_prec)
    end
  end

  defp climb(lhs, [{:op, op} | rest], min_prec) do
    prec = Map.fetch!(@prec, op)

    if prec < min_prec do
      {:ok, lhs, [{:op, op} | rest]}
    else
      next_min = if op == :pow, do: prec, else: prec + 1

      case parse_expr(rest, next_min) do
        {:ok, rhs, rest2} -> climb({op, lhs, rhs}, rest2, min_prec)
        error -> error
      end
    end
  end

  defp climb(lhs, tokens, _min_prec), do: {:ok, lhs, tokens}

  defp parse_unary([{:op, :sub} | rest]) do
    case parse_unary(rest) do
      {:ok, operand, rest2} -> {:ok, {:neg, operand}, rest2}
      error -> error
    end
  end

  defp parse_unary([{:op, :add} | rest]) do
    parse_unary(rest)
  end

  defp parse_unary([{:num, number} | rest]), do: {:ok, number, rest}

  defp parse_unary([{:paren_open} | rest]) do
    case parse_expr(rest, 0) do
      {:ok, inner, [{:paren_close} | rest2]} -> {:ok, inner, rest2}
      {:ok, _inner, _rest2} -> {:error, :missing_closing_paren}
      error -> error
    end
  end

  defp parse_unary([]), do: {:error, :unexpected_end_of_expression}
  defp parse_unary([token | _]), do: {:error, {:unexpected_token, token}}

  # -- evaluator (AST is already the result; numbers only) --

  @doc false
  def eval({op, lhs, rhs}) when op in [:add, :sub, :mul, :div, :mod, :pow] do
    with {:ok, l} <- eval(lhs),
         {:ok, r} <- eval(rhs) do
      do_arith(op, l, r)
    end
  end

  def eval({:neg, operand}) do
    with {:ok, value} <- eval(operand), do: {:ok, -value}
  end

  def eval(number) when is_number(number), do: {:ok, number}

  defp do_arith(:add, l, r), do: {:ok, l + r}
  defp do_arith(:sub, l, r), do: {:ok, l - r}
  defp do_arith(:mul, l, r), do: {:ok, l * r}

  defp do_arith(:div, _l, 0), do: {:error, :division_by_zero}
  defp do_arith(:div, l, r), do: {:ok, l / r}

  defp do_arith(:mod, _l, 0), do: {:error, :modulo_by_zero}
  defp do_arith(:mod, l, r), do: {:ok, rem(l, r)}

  defp do_arith(:pow, l, r), do: {:ok, :math.pow(l, r)}
end
