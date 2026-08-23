defmodule DshBeam.CredentialTest do
  use ExUnit.Case, async: false

  test "resolves an environment reference per request" do
    System.put_env("DSH_CRED_TEST_KEY", "sk-env")

    on_exit(fn -> System.delete_env("DSH_CRED_TEST_KEY") end)

    assert {:ok, "sk-env"} = DshBeam.Credential.resolve({:env, "DSH_CRED_TEST_KEY"})
  end

  test "reports a missing or empty environment variable" do
    System.delete_env("DSH_CRED_TEST_MISSING")

    assert {:error, {:missing_env, "DSH_CRED_TEST_MISSING"}} =
             DshBeam.Credential.resolve({:env, "DSH_CRED_TEST_MISSING"})

    System.put_env("DSH_CRED_TEST_EMPTY", "")
    on_exit(fn -> System.delete_env("DSH_CRED_TEST_EMPTY") end)

    assert {:error, {:missing_env, "DSH_CRED_TEST_EMPTY"}} =
             DshBeam.Credential.resolve({:env, "DSH_CRED_TEST_EMPTY"})
  end

  test "resolves a literal reference" do
    assert {:ok, "sk-literal"} = DshBeam.Credential.resolve({:literal, "sk-literal"})
    assert {:error, :empty_credential} = DshBeam.Credential.resolve({:literal, ""})
  end

  test "rejects an unknown reference shape" do
    assert {:error, {:invalid_credential_ref, :bad}} = DshBeam.Credential.resolve(:bad)
  end
end
