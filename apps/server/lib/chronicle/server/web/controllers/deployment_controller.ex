defmodule Chronicle.Server.Web.Controllers.DeploymentController do
  use Phoenix.Controller, formats: [:json]

  alias Chronicle.Server.Host.Deployment.Manager

  def upload(conn, params) do
    tenant_id = conn.assigns[:tenant_id]

    case extract_upload(params) do
      {:ok, content, filename} ->
        case Manager.provision(content, filename, tenant_id) do
          {:ok, results} ->
            json(conn, %{status: "deployed", results: inspect(results)})
          {:error, reason} ->
            conn |> put_status(400) |> json(%{error: inspect(reason)})
        end

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: reason})
    end
  end

  def redeploy(conn, _params) do
    tenant_id = conn.assigns[:tenant_id]
    json(conn, %{status: "redeploy initiated", tenant: tenant_id})
  end

  def deploy_mock(conn, %{"filename" => filename}) do
    if Application.get_env(:server, :enable_mock_deployment, false) do
      tenant_id = conn.assigns[:tenant_id]

      case File.read(filename) do
        {:ok, content} ->
          case Manager.provision(content, filename, tenant_id) do
            {:ok, results} -> json(conn, %{status: "deployed", results: inspect(results)})
            {:error, reason} -> conn |> put_status(400) |> json(%{error: inspect(reason)})
          end
        {:error, reason} ->
          conn |> put_status(404) |> json(%{error: "File not found: #{inspect(reason)}"})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "mock deployment disabled"})
    end
  end

  defp extract_upload(%{"file" => %Plug.Upload{path: path, filename: filename}}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content, filename}
      {:error, reason} -> {:error, "Failed to read upload: #{reason}"}
    end
  end

  defp extract_upload(%{"content" => content, "filename" => filename}) do
    {:ok, content, filename}
  end

  defp extract_upload(_), do: {:error, "No file provided"}
end
