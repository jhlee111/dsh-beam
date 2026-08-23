defmodule DshBeamWeb.ErrorView do
  @moduledoc false
  # Minimal error page: the status message as plain text (favicon 404s and
  # friends must not crash the endpoint for lack of a template).
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
