#!/bin/sh
set -u

RED="1;31"
GREEN="1;32"
YELLOW="1;33"
LIGHT_CYAN="1;36"

echoColor() {
  echo "\033[$1m $2\033[0m"
}

usage() {
  if [ "${1:-}" != "" ]; then
    echoColor $RED "Error: $1"
  fi
  echoColor $YELLOW '
SCRIPT GENERATE BUILD_RUNNER REPORT

USAGE:
  sh report-gen.sh -f

OPTIONS:
  -h, --help    display this usage message and exit
  -f, --force   scan all folders with pubspec.yaml and run "time sh gen.sh" for those declaring build_runner
'
  exit 1
}

isForce=0
if [ "${1:-}" = "" ]; then
  isForce=1
fi
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)
      isForce=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage "Unknown option: $1"
      ;;
  esac
done

if [ "$isForce" != "1" ]; then
  usage "Missing -f/--force"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echoColor $RED "python3 is required (for JSON escaping + time math)."
  exit 2
fi

json_escape() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1])[1:-1])
PY
}

now_iso_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

echoColor $GREEN "------------ START GEN REPORT ------------ \n"

REPORT_JSON="$ROOT_DIR/report-gen.json"
REPORT_INDEX_HTML="$ROOT_DIR/report-gen-index.html"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t reportgen)"
cleanup() {
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

generatedAt="$(now_iso_utc)"

entries_json=""
sep=""
index=0
matched=0
failed=0
skipped=0

countAllPubspec="$(find "$ROOT_DIR" -name pubspec.yaml | wc -l | tr -d ' ')"
echoColor $LIGHT_CYAN "Found $countAllPubspec pubspec.yaml files. Scanning for build_runner..."

ITEMS_JSON="$TMP_DIR/items.json"
(
  echo "["
  first="1"
  find "$ROOT_DIR" -name pubspec.yaml | while read -r pubspec; do
    dir="$(dirname "$pubspec")"

    if ! grep -q "build_runner" "$pubspec"; then
      continue
    fi

    matched=$(( matched + 1 ))
    index=$(( index + 1 ))

    name="$(basename "$dir")"
    relPath="${dir#$ROOT_DIR/}"
    if [ "$relPath" = "$dir" ]; then
      relPath="."
    fi

    genSh="$dir/gen.sh"
    hasGenSh=0
    if [ -f "$genSh" ]; then
      hasGenSh=1
    fi

    startedAt="$(now_iso_utc)"

    stdoutFile="$TMP_DIR/stdout_$index.txt"
    stderrFile="$TMP_DIR/stderr_$index.txt"

    exitCode=0
    realSeconds=""

    echoColor $YELLOW "===> [$index] Run gen in [$relPath]..." 1>&2

    if [ "$hasGenSh" = "1" ]; then
      (
        cd "$dir" && /usr/bin/time -p sh "./gen.sh"
      ) >"$stdoutFile" 2>"$stderrFile"
      exitCode=$?

      realSeconds="$(grep -E '^real[[:space:]]+' "$stderrFile" | awk '{print $2}' | tr -d '\r' | tail -n 1)"
      if [ "${realSeconds:-}" = "" ]; then
        realSeconds="0"
      fi
    else
      exitCode=3
      realSeconds="0"
      echo "Missing gen.sh in $dir" >"$stderrFile"
      skipped=$(( skipped + 1 ))
    fi

    endedAt="$(now_iso_utc)"

    stdoutTrim="$(tail -n 200 "$stdoutFile" 2>/dev/null || true)"
    stderrTrim="$(tail -n 200 "$stderrFile" 2>/dev/null || true)"

    durationMs="$(python3 - "$realSeconds" <<'PY'
import sys
try:
    s = float(sys.argv[1])
except Exception:
    s = 0.0
print(int(round(s * 1000)))
PY
)"

    status="success"
    if [ "$exitCode" != "0" ]; then
      status="failed"
    fi
    if [ "$hasGenSh" != "1" ]; then
      status="skipped"
    fi

    entry="$(cat <<EOF
{
  "name": "$(json_escape "$name")",
  "path": "$(json_escape "$dir")",
  "relativePath": "$(json_escape "$relPath")",
  "hasBuildRunner": true,
  "hasGenSh": $( [ "$hasGenSh" = "1" ] && echo true || echo false ),
  "status": "$(json_escape "$status")",
  "exitCode": $exitCode,
  "startedAt": "$(json_escape "$startedAt")",
  "endedAt": "$(json_escape "$endedAt")",
  "durationMs": $durationMs,
  "durationSeconds": $realSeconds,
  "stdoutTail": "$(json_escape "$stdoutTrim")",
  "stderrTail": "$(json_escape "$stderrTrim")"
}
EOF
)"

    if [ "$first" = "1" ]; then
      first="0"
    else
      printf '%s\n' ","
    fi
    printf '%s\n' "$entry"

    echoColor $GREEN "---------- Done [$index] status=$status duration=${realSeconds}s ----------\n" 1>&2
  done
  echo "]"
) >"$ITEMS_JSON" || exit 1

python3 - "$ITEMS_JSON" "$REPORT_JSON" "$generatedAt" "$ROOT_DIR" <<'PY'
import json
import sys

items_path, out_path, generated_at, root = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(items_path, "r", encoding="utf-8") as f:
    items = json.load(f)

report = {"generatedAt": generated_at, "root": root, "items": items}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
if [ "$?" != "0" ]; then
  echoColor $RED "Failed to write report-gen.json (items json invalid?)"
  exit 1
fi

echoColor $GREEN "Wrote report to: $REPORT_JSON"

REPORT_VIEWER_HTML="$ROOT_DIR/report-gen.html"

python3 - "$REPORT_JSON" "$REPORT_VIEWER_HTML" "$REPORT_INDEX_HTML" <<'PY'
import json
import sys

report_json, out_picker_html, out_embedded_html = sys.argv[1], sys.argv[2], sys.argv[3]

with open(report_json, "r", encoding="utf-8") as f:
    report = json.load(f)

def template_html() -> str:
    # Single source of truth for UI (no dependency on external .html file).
    return """<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>Gen Report Viewer</title>
    <style>
      :root {
        --bg: #0b1020;
        --panel: #0f1835;
        --text: #e8ecff;
        --muted: #a9b4e6;
        --border: rgba(255, 255, 255, 0.12);
        --success: #23c483;
        --failed: #ff4d4f;
        --skipped: #f5a524;
      }
      html,
      body {
        height: 100%;
      }
      body {
        margin: 0;
        font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, "Apple Color Emoji",
          "Segoe UI Emoji";
        background: radial-gradient(800px 500px at 80% 20%, rgba(35, 196, 131, 0.12), transparent 60%), var(--bg);
        color: var(--text);
      }
      a {
        color: inherit;
      }
      .wrap {
        max-width: 1100px;
        margin: 28px auto;
        padding: 0 16px 40px;
      }
      .header {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        align-items: center;
        justify-content: space-between;
        margin-bottom: 16px;
      }
      .title {
        display: flex;
        flex-direction: column;
        gap: 4px;
      }
      .title h1 {
        font-size: 18px;
        margin: 0;
        letter-spacing: 0.2px;
      }
      .title .meta {
        font-size: 12px;
        color: var(--muted);
      }
      .controls {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        align-items: center;
        justify-content: flex-end;
      }
      .panel {
        background: linear-gradient(180deg, rgba(255, 255, 255, 0.03), transparent 40%), var(--panel);
        border: 1px solid var(--border);
        border-radius: 12px;
        padding: 14px;
        box-shadow: 0 10px 30px rgba(0, 0, 0, 0.32);
      }
      .controls .panel {
        padding: 10px 12px;
      }
      input[type="file"] {
        color: var(--muted);
        font-size: 12px;
      }
      .row {
        display: grid;
        grid-template-columns: 1.2fr 0.8fr;
        gap: 14px;
        margin-top: 12px;
      }
      .row.single {
        grid-template-columns: 1fr;
      }
      @media (max-width: 980px) {
        .row {
          grid-template-columns: 1fr;
        }
      }
      .kpis {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 12px;
      }
      @media (max-width: 800px) {
        .kpis {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }
      .kpi {
        padding: 12px;
        border-radius: 12px;
        border: 1px solid var(--border);
        background: rgba(255, 255, 255, 0.02);
      }
      .kpi .label {
        font-size: 12px;
        color: var(--muted);
      }
      .kpi .value {
        font-size: 18px;
        margin-top: 6px;
        font-variant-numeric: tabular-nums;
      }
      .filters {
        display: flex;
        gap: 10px;
        flex-wrap: wrap;
        align-items: center;
      }
      .filters label {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        font-size: 12px;
        color: var(--muted);
      }
      .filters input[type="checkbox"] {
        accent-color: #e6e6e6;
      }
      .sort {
        display: inline-flex;
        gap: 8px;
        align-items: center;
        font-size: 12px;
        color: var(--muted);
      }
      select {
        background: rgba(255, 255, 255, 0.04);
        border: 1px solid var(--border);
        border-radius: 10px;
        padding: 6px 8px;
        color: var(--text);
      }
      details {
        margin-top: 8px;
      }
      summary {
        cursor: pointer;
        color: var(--muted);
        font-size: 12px;
        user-select: none;
      }
      pre {
        margin: 10px 0 0;
        padding: 10px;
        border-radius: 10px;
        border: 1px solid var(--border);
        background: rgba(0, 0, 0, 0.28);
        color: #d8defc;
        overflow: auto;
        max-height: 260px;
        font-size: 12px;
        line-height: 1.35;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
        white-space: pre-wrap;
        word-break: break-word;
      }
      .hint {
        margin-top: 10px;
        font-size: 12px;
        color: var(--muted);
      }
      .chartWrap {
        height: 360px;
      }
      .viewToggle {
        display: inline-flex;
        gap: 8px;
        align-items: center;
        font-size: 12px;
        color: var(--muted);
      }
      .btn {
        border: 1px solid var(--border);
        background: rgba(255, 255, 255, 0.04);
        color: var(--text);
        border-radius: 10px;
        padding: 6px 10px;
        cursor: pointer;
        font-size: 12px;
      }
      .btn.active {
        background: rgba(255, 255, 255, 0.08);
        border-color: rgba(255, 255, 255, 0.26);
      }
      .tableWrap {
        overflow: auto;
      }
      table {
        width: 100%;
        border-collapse: collapse;
        font-size: 12px;
      }
      thead th {
        position: sticky;
        top: 0;
        z-index: 2;
        background: rgba(15, 24, 53, 0.92);
        backdrop-filter: blur(8px);
        text-align: left;
        color: rgba(232, 236, 255, 0.92);
        border-bottom: 1px solid var(--border);
        padding: 10px 10px;
        white-space: nowrap;
      }
      tbody td {
        border-bottom: 1px solid rgba(255, 255, 255, 0.08);
        padding: 10px 10px;
        vertical-align: top;
      }
      tbody tr:hover {
        background: rgba(255, 255, 255, 0.03);
      }
      .mono {
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      }
      .cellName {
        font-weight: 600;
      }
      .cellPath {
        color: var(--muted);
        word-break: break-all;
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="header">
        <div class="title">
          <h1>Build Runner Gen Report</h1>
          <div class="meta" id="meta">Pick a `report-gen.json` file to view.</div>
        </div>
        <div class="controls">
          <div class="panel" id="pickerPanel">
            <input id="file" type="file" accept=".json,application/json" />
          </div>
        </div>
      </div>

      <div class="panel">
        <div class="kpis">
          <div class="kpi">
            <div class="label">Total</div>
            <div class="value" id="kpiTotal">-</div>
          </div>
          <div class="kpi">
            <div class="label">Success</div>
            <div class="value" id="kpiSuccess">-</div>
          </div>
          <div class="kpi">
            <div class="label">Failed</div>
            <div class="value" id="kpiFailed">-</div>
          </div>
          <div class="kpi">
            <div class="label">Total duration</div>
            <div class="value" id="kpiDuration">-</div>
          </div>
        </div>

        <div style="height: 12px"></div>

        <div class="filters">
          <label><input type="checkbox" id="showSuccess" checked /> show success</label>
          <label><input type="checkbox" id="showFailed" checked /> show failed</label>
          <label><input type="checkbox" id="showSkipped" checked /> show skipped</label>
          <label style="margin-left:auto; display:flex; align-items:center; gap:8px">
            <span>search</span>
            <input
              id="search"
              type="text"
              placeholder="name/path..."
              style="
                background: rgba(255, 255, 255, 0.04);
                border: 1px solid var(--border);
                border-radius: 10px;
                padding: 6px 8px;
                color: var(--text);
                font-size: 12px;
                min-width: 180px;
              "
            />
          </label>
          <span class="sort">
            sort:
            <select id="sort">
              <option value="duration_desc">duration ↓</option>
              <option value="duration_asc">duration ↑</option>
              <option value="name_asc">name A→Z</option>
              <option value="name_desc">name Z→A</option>
              <option value="status">status</option>
            </select>
          </span>
          <span class="viewToggle">
            view:
            <button class="btn active" id="viewChart" type="button">chart</button>
            <button class="btn" id="viewTable" type="button">table</button>
          </span>
        </div>
      </div>

      <div class="row single" id="viewRow">
        <div class="panel" id="chartPanel" style="display: block">
          <div class="chartWrap">
            <canvas id="chart"></canvas>
          </div>
          <div class="hint">Chart shows duration (seconds) for filtered items.</div>
        </div>
        <div class="panel" id="tablePanel" style="display: none">
          <div id="tableWrap" class="tableWrap" style="display: block">
            <table>
              <thead>
                <tr>
                  <th style="width: 30%">Name</th>
                  <th style="width: 38%">Path</th>
                  <th>Status</th>
                  <th>Duration</th>
                  <th>Exit</th>
                  <th>Logs</th>
                </tr>
              </thead>
              <tbody id="tableBody"></tbody>
            </table>
          </div>
        </div>
      </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
    <script>
      const $ = (id) => document.getElementById(id);

      let report = window.__REPORT_GEN__ ?? null;
      let chart = null;
      let activeView = "chart"; // chart | table

      const statusOrder = { failed: 0, skipped: 1, success: 2 };

      function fmtSeconds(ms) {
        if (!Number.isFinite(ms)) return "-";
        const s = ms / 1000;
        if (s < 60) return `${s.toFixed(2)}s`;
        const m = Math.floor(s / 60);
        const r = s - m * 60;
        return `${m}m ${r.toFixed(1)}s`;
      }

      function filteredItems() {
        if (!report?.items) return [];
        const show = {
          success: $("showSuccess").checked,
          failed: $("showFailed").checked,
          skipped: $("showSkipped").checked,
        };
        const q = ($("search")?.value || "").trim().toLowerCase();
        let items = report.items.filter((it) => show[it.status] !== false);
        if (q) {
          items = items.filter((it) => {
            const n = String(it.name || "").toLowerCase();
            const p = String(it.relativePath || it.path || "").toLowerCase();
            return n.includes(q) || p.includes(q);
          });
        }

        const sort = $("sort").value;
        items.sort((a, b) => {
          if (sort === "duration_desc") return (b.durationMs ?? 0) - (a.durationMs ?? 0);
          if (sort === "duration_asc") return (a.durationMs ?? 0) - (b.durationMs ?? 0);
          if (sort === "name_asc") return (a.name ?? "").localeCompare(b.name ?? "");
          if (sort === "name_desc") return (b.name ?? "").localeCompare(a.name ?? "");
          if (sort === "status") return (statusOrder[a.status] ?? 9) - (statusOrder[b.status] ?? 9);
          return 0;
        });
        return items;
      }

      function renderKpis() {
        const items = report?.items ?? [];
        const total = items.length;
        const success = items.filter((x) => x.status === "success").length;
        const failed = items.filter((x) => x.status === "failed").length;
        const durationMs = items.reduce((acc, x) => acc + (Number(x.durationMs) || 0), 0);

        $("kpiTotal").textContent = total;
        $("kpiSuccess").textContent = success;
        $("kpiFailed").textContent = failed;
        $("kpiDuration").textContent = fmtSeconds(durationMs);

        const metaParts = [];
        if (report?.generatedAt) metaParts.push(`generatedAt: ${report.generatedAt}`);
        if (report?.root) metaParts.push(`root: ${report.root}`);
        $("meta").textContent = metaParts.length ? metaParts.join(" • ") : "Loaded report.";
      }

      function escapeHtml(s) {
        return String(s)
          .replaceAll("&", "&amp;")
          .replaceAll("<", "&lt;")
          .replaceAll(">", "&gt;")
          .replaceAll('"', "&quot;")
          .replaceAll("'", "&#039;");
      }

      function renderTable(items) {
        const tbody = $("tableBody");
        tbody.innerHTML = "";

        if (!items.length) {
          tbody.innerHTML = `<tr><td colspan="6" class="hint">No items (check filters / search).</td></tr>`;
          return;
        }

        for (const it of items) {
          const name = it.name ?? "(unknown)";
          const path = it.relativePath ?? it.path ?? "";
          const status = it.status ?? "skipped";
          const duration = fmtSeconds(Number(it.durationMs) || 0);
          const exit = it.exitCode ?? "-";
          const stderr = (it.stderrTail || "").trim();
          const stdout = (it.stdoutTail || "").trim();

          const tr = document.createElement("tr");
          tr.innerHTML = `
            <td><div class="cellName">${escapeHtml(name)}</div></td>
            <td class="mono cellPath">${escapeHtml(path)}</td>
            <td class="mono">${escapeHtml(status)}</td>
            <td class="mono">${escapeHtml(duration)}</td>
            <td class="mono">${escapeHtml(exit)}</td>
            <td>
              <details>
                <summary>view</summary>
                <div style="display:grid; grid-template-columns: 1fr; gap: 10px; margin-top: 8px">
                  <div>
                    <div class="hint">stderr</div>
                    <pre>${escapeHtml(stderr || "(empty)")}</pre>
                  </div>
                  <div>
                    <div class="hint">stdout</div>
                    <pre>${escapeHtml(stdout || "(empty)")}</pre>
                  </div>
                </div>
              </details>
            </td>
          `;
          tbody.appendChild(tr);
        }
      }

      function renderChart(items) {
        const labels = items.map((x) => x.name ?? x.relativePath ?? "unknown");
        const durations = items.map((x) => (Number(x.durationMs) || 0) / 1000);
        const colors = items.map((x) => {
          if (x.status === "failed") return "rgba(255, 255, 255, 0.95)";
          if (x.status === "skipped") return "rgba(255, 255, 255, 0.35)";
          return "rgba(255, 255, 255, 0.65)";
        });

        const ctx = $("chart");
        if (chart) chart.destroy();

        chart = new Chart(ctx, {
          type: "bar",
          data: {
            labels,
            datasets: [
              {
                label: "Duration (seconds)",
                data: durations,
                backgroundColor: colors,
                borderColor: colors.map((c) => c.replace(/0\.(\d+)/, "1")),
                borderWidth: 1,
              },
            ],
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            scales: {
              y: {
                beginAtZero: true,
                ticks: { color: "rgba(232,236,255,0.85)" },
                grid: { color: "rgba(255,255,255,0.08)" },
              },
              x: {
                ticks: { color: "rgba(232,236,255,0.85)" },
                grid: { display: false },
              },
            },
            plugins: {
              legend: {
                labels: { color: "rgba(232,236,255,0.92)" },
              },
              tooltip: {
                callbacks: {
                  label: (ctx) => ` ${ctx.dataset.label}: ${ctx.parsed.y.toFixed(2)}s`,
                },
              },
            },
          },
        });
      }

      function render() {
        if (!report) return;
        renderKpis();
        const items = filteredItems();
        if (activeView === "chart") renderChart(items);
        else renderTable(items);
      }

      function setView(view) {
        activeView = view;
        $("viewChart").classList.toggle("active", view === "chart");
        $("viewTable").classList.toggle("active", view === "table");
        $("chartPanel").style.display = view === "chart" ? "block" : "none";
        $("tablePanel").style.display = view === "table" ? "block" : "none";
        render();
      }

      $("file").addEventListener("change", async (e) => {
        const file = e.target.files?.[0];
        if (!file) return;
        const text = await file.text();
        try {
          report = JSON.parse(text);
          setView("chart");
        } catch (err) {
          report = null;
          $("meta").textContent = "Invalid JSON file.";
        }
      });

      $("showSuccess").addEventListener("change", render);
      $("showFailed").addEventListener("change", render);
      $("showSkipped").addEventListener("change", render);
      $("sort").addEventListener("change", render);
      $("search").addEventListener("input", render);
      $("viewChart").addEventListener("click", () => setView("chart"));
      $("viewTable").addEventListener("click", () => setView("table"));

      if (report) {
        const picker = $("pickerPanel");
        if (picker) picker.style.display = "none";
        setView("chart");
      }
    </script>
  </body>
</html>
"""


tpl = template_html()

# write picker viewer (no embedded report)
with open(out_picker_html, "w", encoding="utf-8") as f:
    f.write(tpl)

# write embedded viewer
inject = "<script>window.__REPORT_GEN__=" + json.dumps(report, ensure_ascii=False) + ";</script>\n"
if "</head>" in tpl:
    embedded_html = tpl.replace("</head>", inject + "</head>", 1)
else:
    embedded_html = inject + tpl

with open(out_embedded_html, "w", encoding="utf-8") as f:
    f.write(embedded_html)
PY
if [ "$?" != "0" ]; then
  echoColor $RED "Failed to write report-gen-index.html"
  exit 1
fi

echoColor $GREEN "Wrote viewer to: $REPORT_VIEWER_HTML"
echoColor $GREEN "Wrote embedded viewer to: $REPORT_INDEX_HTML"

if command -v open >/dev/null 2>&1; then
  open "$REPORT_INDEX_HTML" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$REPORT_INDEX_HTML" >/dev/null 2>&1 || true
elif command -v cmd.exe >/dev/null 2>&1; then
  cmd.exe /c start "" "$REPORT_INDEX_HTML" >/dev/null 2>&1 || true
fi

failedCount="$(python3 - "$REPORT_JSON" <<'PY'
import json, sys
report=json.load(open(sys.argv[1], 'r', encoding='utf-8'))
items=report.get('items') or []
print(sum(1 for x in items if x.get('status')=='failed'))
PY
)"
if [ "${failedCount:-0}" != "0" ]; then
  echoColor $RED "Some folders failed ($failedCount). See report-gen.json for details."
  exit 1
fi

echoColor $GREEN "------------ GEN REPORT DONE ------------ \n"
