defmodule DshBeam.Credential do
  @moduledoc """
  A credential reference. Configuration carries a NAME, never a literal key:
  the original harness's `apiKeyEnv: CredentialRef` — "configuration carries
  only this name — a literal key is not a configuration value."

  resolve/1 produces the key per request, so a credential change (an updated
  environment variable, a key typed into the console) reaches the next
  request without re-registering the provider.

  References:

  - `{:env, name}` — resolve the environment variable each request.
  - `{:literal, value}` — a literal key (typed into the console, or a test key).
  """

  @typedoc "A credential reference carried by configuration."
  @type ref :: {:env, String.t()} | {:literal, String.t()}

  @doc "Resolve a credential reference to a usable key."
  @spec resolve(ref() | term()) :: {:ok, String.t()} | {:error, term()}
  def resolve({:env, name}) when is_binary(name) do
    case System.get_env(name) do
      nil -> {:error, {:missing_env, name}}
      value when value == "" -> {:error, {:missing_env, name}}
      value -> {:ok, value}
    end
  end

  def resolve({:literal, value}) when is_binary(value) do
    if value == "", do: {:error, :empty_credential}, else: {:ok, value}
  end

  def resolve(other), do: {:error, {:invalid_credential_ref, other}}
end
