defmodule Chronicle.Server.Web.Controllers.ProcessDefinitionController do
  use Phoenix.Controller, formats: [:html, :json]

  alias Chronicle.Engine.Diagrams.DiagramStore
  alias Chronicle.Persistence.Queries
  alias Chronicle.Server.Host.Deployment.Manager

  def app(conn, _params) do
    html(conn, page_html())
  end

  def index(conn, _params) do
    tenant_id = conn.assigns[:tenant_id]

    deployments =
      tenant_id
      |> Queries.load_deployments("bpmn")
      |> Enum.uniq_by(& &1.name)
      |> Enum.map(&deployment_json/1)

    json(conn, %{deployments: deployments})
  end

  def show(conn, %{"id" => id}) do
    case Queries.load_deployment_by_id(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "deployment not found"})

      deployment ->
        json(conn, %{deployment: deployment_json(deployment, include_content: true)})
    end
  end

  def create(conn, params) do
    save_new_version(conn, params)
  end

  def update(conn, %{"id" => id} = params) do
    case Queries.load_deployment_by_id(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "deployment not found"})
      deployment -> save_new_version(conn, Map.put_new(params, "name", deployment.name))
    end
  end

  def delete(conn, %{"id" => id}) do
    tenant_id = conn.assigns[:tenant_id]

    case Queries.delete_deployment_by_id(id) do
      {:ok, deployment} ->
        version = unpack_version(deployment.version)
        :ok = DiagramStore.unregister(deployment.name, version, tenant_id)
        json(conn, %{status: "deleted", id: deployment.id})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "deployment not found"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def template(conn, params) do
    name = Map.get(params, "name", "new-process") |> slug_name()

    json(conn, %{
      content:
        Jason.encode!(
          %{
            name: name,
            version: 1,
            nodes: [
              %{
                id: 1,
                key: "start",
                label: "Start",
                type: "blankStartEvent",
                position: %{x: 160, y: 180}
              },
              %{
                id: 2,
                key: "done",
                label: "Done",
                type: "blankEndEvent",
                position: %{x: 420, y: 180}
              }
            ],
            connections: [
              %{id: "flow_start_done", from: 1, to: 2}
            ]
          },
          pretty: true
        )
    })
  end

  defp save_new_version(conn, params) do
    tenant_id = conn.assigns[:tenant_id]
    source_content = Map.get(params, "content")

    with true <- is_binary(source_content),
         {:ok, name, content} <- prepare_content(source_content, tenant_id) do
      filename = "#{name}.bpjs"

      case Manager.provision(content, filename, tenant_id) do
        {:ok, results} ->
          json(conn, %{
            status: "deployed",
            name: name,
            results: inspect(results),
            content: content
          })

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: inspect(reason)})
      end
    else
      false -> conn |> put_status(400) |> json(%{error: "content is required"})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  defp prepare_content(content, tenant_id) do
    with {:ok, parsed} <- Jason.decode(content),
         {:ok, name} <- process_name(parsed) do
      version = Queries.latest_deployment_version(tenant_id, name, "bpmn") + 1
      {:ok, name, parsed |> put_versions(version) |> Jason.encode!(pretty: true)}
    end
  end

  defp process_name(%{"processes" => [%{"name" => name} | _]})
       when is_binary(name) and name != "",
       do: {:ok, name}

  defp process_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}

  defp process_name(_), do: {:error, "BPJS content must include a process name"}

  defp put_versions(%{"processes" => processes} = payload, version) when is_list(processes) do
    Map.put(payload, "processes", Enum.map(processes, &Map.put(&1, "version", version)))
  end

  defp put_versions(payload, version), do: Map.put(payload, "version", version)

  defp deployment_json(deployment, opts \\ []) do
    base = %{
      id: deployment.id,
      tenantId: deployment.tenant_id,
      name: deployment.name,
      version: unpack_version(deployment.version),
      kind: deployment.kind,
      deployedAt: deployment.deployed_at
    }

    if Keyword.get(opts, :include_content, false) do
      Map.put(base, :content, deployment.content)
    else
      base
    end
  end

  defp unpack_version(0), do: nil
  defp unpack_version(version), do: version

  defp slug_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "new-process"
      slug -> slug
    end
  end

  defp page_html do
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Chronicle Processes</title>
      <script src="https://cdn.tailwindcss.com"></script>
      <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;700&display=swap" rel="stylesheet">
      <link href="/editor/index.css" rel="stylesheet">
      <style>
        :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        * { box-sizing: border-box; }
        body { margin: 0; background: #f8fafc; color: #0f172a; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        body::before { content: ""; position: fixed; inset: 0; pointer-events: none; background-image: radial-gradient(#cbd5e1 1px, transparent 1px); background-size: 16px 16px; opacity: .35; }
        main { min-height: 100vh; position: relative; z-index: 1; }
        .dashboard h1 { font-size: 18px; line-height: 1; font-weight: 800; margin: 0; letter-spacing: -.01em; color: #0f172a; }
        .dashboard h2 { font-size: 11px; margin: 0; color: #64748b; font-weight: 800; text-transform: uppercase; letter-spacing: .08em; }
        .dashboard button { min-height: 36px; border: 1px solid #cbd5e1; background: #ffffff; color: #475569; padding: 8px 12px; border-radius: 8px; cursor: pointer; font-weight: 700; line-height: 1; box-shadow: 0 1px 1px rgba(15,23,42,.03); display: inline-flex; align-items: center; justify-content: center; gap: 8px; }
        .dashboard button:hover { background: #f8fafc; border-color: #94a3b8; color: #0f172a; }
        .dashboard button.primary { background: #0d9488; color: #fff; border-color: #0d9488; box-shadow: 0 6px 12px rgba(13,148,136,.18); }
        .dashboard button.primary:hover { background: #0f766e; border-color: #0f766e; color: #fff; }
        .dashboard button.danger { color: #dc2626; border-color: #fecaca; }
        .dashboard button:disabled { opacity: .55; cursor: wait; }
        .dashboard { min-height: 100vh; display: grid; grid-template-rows: auto 1fr; gap: 18px; padding: 18px 24px 24px; }
        .dashboard-head { display: flex; justify-content: flex-end; gap: 18px; align-items: center; flex-wrap: wrap; }
        .dashboard-head > div:first-child { display: none; }
        .create { display: flex; align-items: center; flex-wrap: nowrap; min-height: 40px; border: 1px solid #cbd5e1; border-radius: 10px; overflow: hidden; background: #fff; box-shadow: 0 1px 2px rgba(15,23,42,.04); }
        .create:focus-within { border-color: #0d9488; box-shadow: 0 0 0 3px rgba(13,148,136,.14); }
        .dashboard .create input { width: min(340px, 42vw); min-height: 40px; border: 0; border-radius: 0; box-shadow: none; background: #fff; padding: 0 14px; }
        .dashboard .create button { min-height: 40px; border: 0; border-left: 1px solid #cbd5e1; border-radius: 0; box-shadow: none; white-space: nowrap; padding: 0 16px; }
        .summary { color: #64748b; margin-top: 6px; font-size: 13px; font-weight: 600; }
        .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(270px, 1fr)); align-content: start; gap: 14px; }
        .dashboard .card { width: 100%; min-height: 150px; padding: 17px; text-align: left; display: grid; grid-template-rows: 1fr auto; gap: 16px; border-color: #e2e8f0; background: rgba(255,255,255,.96); box-shadow: 0 8px 22px rgba(15,23,42,.06); color: #0f172a; }
        .dashboard .card:hover, .dashboard .card:focus-visible { border-color: #0d9488; box-shadow: 0 0 0 3px rgba(13,148,136,.14), 0 14px 28px rgba(15,23,42,.08); outline: none; transform: translateY(-1px); }
        .card-wrap { position: relative; min-width: 0; }
        .dashboard .card-action { position: absolute; right: 10px; top: 10px; width: 34px; height: 34px; min-height: 34px; display: grid; place-items: center; padding: 0; border-radius: 8px; border-color: #fee2e2; color: #ef4444; background: rgba(255,255,255,.96); box-shadow: none; }
        .dashboard .card-action:hover, .dashboard .card-action:focus-visible { background: #fef2f2; border-color: #fecaca; color: #dc2626; outline: none; }
        .card-title { display: block; padding-right: 40px; font-size: 16px; font-weight: 800; line-height: 1.25; overflow-wrap: anywhere; }
        .card-meta { color: #64748b; font-size: 12px; line-height: 1.55; font-weight: 600; }
        .card-meta strong { display: inline-flex; align-items: center; min-height: 22px; padding: 2px 8px; margin-right: 6px; border-radius: 999px; background: #ecfdf5; color: #047857; font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .04em; }
        .empty { border: 1px dashed #cbd5e1; border-radius: 12px; min-height: 180px; display: grid; place-items: center; color: #64748b; background: rgba(255,255,255,.8); font-weight: 700; }
        .editor { min-height: 100vh; display: none; grid-template-rows: 1fr; padding: 0; }
        .editor.open { display: grid; }
        .dashboard input { font: inherit; border: 1px solid #cbd5e1; border-radius: 8px; padding: 9px 11px; background: #fff; color: #0f172a; box-shadow: 0 1px 1px rgba(15,23,42,.03); font-weight: 600; }
        .dashboard input::placeholder { color: #94a3b8; font-weight: 600; }
        .dashboard input:focus { outline: none; border-color: #0d9488; box-shadow: 0 0 0 3px rgba(13,148,136,.14); }
        .workflow-shell { height: 100vh; min-height: 100vh; overflow: hidden; background: #fff; }
        .workflow-shell > div, .workflow-shell .react-flow { width: 100%; height: 100%; min-height: 100%; }
        .status { display: none; }
        .status.error { color: #9f1d20; }
        [hidden] { display: none !important; }
        @media (max-width: 760px) { .dashboard { padding: 14px; } .dashboard-head { align-items: stretch; } .create { width: 100%; } .dashboard .create input { width: 100%; min-width: 0; } .cards { grid-template-columns: 1fr; } }
      </style>
    </head>
    <body>
      <main>
        <section id="dashboard" class="dashboard">
          <div class="dashboard-head">
            <div>
              <h2>Deployed Processes</h2>
              <div id="summary" class="summary">Loading deployments...</div>
            </div>
            <div class="create">
              <input id="new-name" placeholder="new-process" aria-label="New process name" />
              <button id="new" class="primary">
                <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14"/><path d="M5 12h14"/></svg>
                Create
              </button>
            </div>
          </div>
          <div id="cards" class="cards"></div>
        </section>
        <section id="editor" class="editor">
          <div id="workflow-editor" class="workflow-shell"></div>
          <div id="status" class="status"></div>
        </section>
      </main>
      <script type="module">
        const editorHostUrl = '/editor/host.js';
        const tenantId = localStorage.getItem('chronicleTenantId') || '00000000-0000-0000-0000-000000000000';
        const headers = { 'content-type': 'application/json', 'x-tenant-id': tenantId };
        const state = { selected: null, deployments: [], editorMount: null, currentName: null };
        const dashboard = document.querySelector('#dashboard');
        const editor = document.querySelector('#editor');
        const cards = document.querySelector('#cards');
        const summary = document.querySelector('#summary');
        const newNameInput = document.querySelector('#new-name');
        const statusEl = document.querySelector('#status');

        function setStatus(text, isError = false) {
          statusEl.textContent = text;
          statusEl.className = isError ? 'status error' : 'status';
        }

        async function request(url, options = {}) {
          const res = await fetch(url, { ...options, headers: { ...headers, ...(options.headers || {}) } });
          const body = await res.json().catch(() => ({}));
          if (!res.ok) throw new Error(body.error || res.statusText);
          return body;
        }

        function showDashboard() {
          dashboard.hidden = false;
          editor.classList.remove('open');
        }

        function showEditor() {
          dashboard.hidden = true;
          editor.classList.add('open');
        }

        async function ensureWorkflowEditor() {
          if (!window.ChronicleWorkflowEditor) {
            await import(editorHostUrl);
          }
          return window.ChronicleWorkflowEditor;
        }

        async function mountWorkflowEditor({ id, name, version, content }) {
          state.selected = id;
          state.currentName = name;
          showEditor();
          setStatus('Loading workflow editor...');

          try {
            const workflow = await ensureWorkflowEditor();
            state.editorMount?.unmount?.();
            state.editorMount = await workflow.mount('#workflow-editor', {
              content,
              processName: name,
              onBack: showDashboard,
              onSave: deployFromEditor
            });
            setStatus(version ? `Editing ${name} v${version}.` : `${name} draft ready.`);
          } catch (err) {
            setStatus(`Workflow editor failed to load. Start the editor dev server on port 3000. ${err.message}`, true);
          }
        }

        function renderCards() {
          cards.innerHTML = '';
          summary.textContent = `${state.deployments.length} deployed process version(s)`;

          for (const item of state.deployments) {
            const wrap = document.createElement('div');
            wrap.className = 'card-wrap';

            const button = document.createElement('button');
            button.className = 'card';
            button.innerHTML = `<span><strong class="card-title">${item.name}</strong></span><span class="card-meta"><strong>v${item.version ?? 'latest'}</strong>${item.kind}<br>${new Date(item.deployedAt).toLocaleString()}</span>`;
            button.onclick = () => loadDeployment(item.id);
            wrap.appendChild(button);

            const deleteButton = document.createElement('button');
            deleteButton.className = 'card-action';
            deleteButton.type = 'button';
            deleteButton.title = `Delete ${item.name} v${item.version ?? 'latest'}`;
            deleteButton.setAttribute('aria-label', deleteButton.title);
            deleteButton.innerHTML = '<svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v5"/><path d="M14 11v5"/></svg>';
            deleteButton.onclick = (event) => {
              event.stopPropagation();
              deleteDeployment(item);
            };
            wrap.appendChild(deleteButton);
            cards.appendChild(wrap);
          }

          if (state.deployments.length === 0) {
            cards.innerHTML = '<div class="empty">No deployed processes yet.</div>';
          }
        }

        async function refresh() {
          const data = await request('/api/process-definitions');
          state.deployments = data.deployments;
          renderCards();
          setStatus(`Loaded ${state.deployments.length} deployment(s).`);
        }

        async function loadDeployment(id) {
          const data = await request(`/api/process-definitions/${id}`);
          await mountWorkflowEditor({
            id,
            name: data.deployment.name,
            version: data.deployment.version,
            content: data.deployment.content
          });
        }

        async function newProcess() {
          const processName = newNameInput.value.trim() || 'new-process';
          const data = await request(`/api/process-definitions/template?name=${encodeURIComponent(processName)}`);
          await mountWorkflowEditor({
            id: null,
            name: processName,
            version: null,
            content: data.content
          });
        }

        async function deployFromEditor(payload) {
          const content = payload.content;
          try {
            JSON.parse(content);
          } catch (err) {
            setStatus(`Invalid JSON: ${err.message}`, true);
            return;
          }

          const url = state.selected ? `/api/process-definitions/${state.selected}` : '/api/process-definitions';
          const method = state.selected ? 'PUT' : 'POST';
          const data = await request(url, {
            method,
            body: JSON.stringify({ name: payload.projectName || state.currentName, content })
          });
          await refresh();
          setStatus(`Deployed ${data.name}.`);
          if (payload.quit) showDashboard();
        }

        async function deleteDeployment(item) {
          if (!confirm(`Delete ${item.name} v${item.version ?? 'latest'}?`)) return;
          await request(`/api/process-definitions/${item.id}`, { method: 'DELETE' });
          if (state.selected === item.id) {
            state.selected = null;
            state.currentName = null;
            state.editorMount?.unmount?.();
            state.editorMount = null;
            showDashboard();
          }
          await refresh();
          setStatus(`Deleted ${item.name}.`);
        }

        document.querySelector('#new').onclick = () => newProcess().catch(err => setStatus(err.message, true));
        refresh().then(showDashboard).catch(err => setStatus(err.message, true));
      </script>
    </body>
    </html>
    """
  end
end
