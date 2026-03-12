#!/bin/bash
# Vibe Office - Pixel Art Plugin/Skill/Agent Visualizer
# Scans your ~/.claude/plugins/cache/ directory and generates an interactive HTML dashboard
# Usage: ./vibe-office.sh [output_file]
#   output_file: path to write HTML (default: ./vibe-office.html)

set -euo pipefail

OUTPUT="${1:-./vibe-office.html}"
PLUGIN_BASE="$HOME/.claude/plugins/cache"

# Find the plugin root - it may be nested one level (e.g., fe-vibe/)
PLUGIN_ROOT=""
if [ -d "$PLUGIN_BASE" ]; then
  for candidate in "$PLUGIN_BASE" "$PLUGIN_BASE"/*/; do
    if ls "$candidate"/*/latest/skills 2>/dev/null | head -1 > /dev/null 2>&1 || \
       ls "$candidate"/fe-*/*/skills 2>/dev/null | head -1 > /dev/null 2>&1; then
      PLUGIN_ROOT="$candidate"
      break
    fi
  done
  if [ -z "$PLUGIN_ROOT" ]; then
    PLUGIN_ROOT="$PLUGIN_BASE"
  fi
fi

if [ ! -d "$PLUGIN_ROOT" ]; then
  echo "Error: No plugins found at $PLUGIN_BASE"
  echo "Make sure you have Claude Code plugins installed."
  exit 1
fi

echo "Scanning plugins in: $PLUGIN_ROOT"

# Extract description from frontmatter of a .md file
# Looks for: description: <text> between --- markers
extract_description() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo ""
    return
  fi
  # Read frontmatter between first two --- lines, extract description field
  local in_front=false
  local desc=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if $in_front; then
        break
      else
        in_front=true
        continue
      fi
    fi
    if $in_front; then
      if [[ "$line" =~ ^description:\ *(.*) ]]; then
        desc="${BASH_REMATCH[1]}"
        # Strip surrounding quotes if present
        desc="${desc#\"}"
        desc="${desc%\"}"
        desc="${desc#\'}"
        desc="${desc%\'}"
      fi
    fi
  done < "$file"
  echo "$desc"
}

# Escape string for safe JSON embedding
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  echo "$s"
}

# Build JSON for each plugin
PLUGIN_JSON="{"
FIRST_PLUGIN=true

for plugin_dir in "$PLUGIN_ROOT"/*/; do
  [ -d "$plugin_dir" ] || continue
  plugin_name=$(basename "$plugin_dir")
  [[ "$plugin_name" == "node_modules" || "$plugin_name" == ".git" ]] && continue

  # Find the version directory (must contain skills/ or agents/ to be a real plugin)
  version_dir=""
  version=""
  for vd in "$plugin_dir"/*/; do
    [ -d "$vd" ] || continue
    if [ -d "$vd/skills" ] || [ -d "$vd/agents" ]; then
      version_dir="$vd"
      version=$(basename "$vd")
      break
    fi
  done
  [ -z "$version_dir" ] && continue

  # Collect skills with descriptions
  skills_json="["
  first_skill=true
  if [ -d "$version_dir/skills" ]; then
    for skill_dir in "$version_dir/skills"/*/; do
      [ -d "$skill_dir" ] || continue
      skill_name=$(basename "$skill_dir")

      # Try SKILL.md first, then README.md for description
      desc=""
      if [ -f "$skill_dir/SKILL.md" ]; then
        desc=$(extract_description "$skill_dir/SKILL.md")
      fi
      if [ -z "$desc" ] && [ -f "$skill_dir/README.md" ]; then
        # Grab first non-heading, non-empty line from README as fallback
        desc=$(grep -m1 -v '^#\|^$\|^---' "$skill_dir/README.md" 2>/dev/null | head -1)
      fi
      desc=$(json_escape "${desc:-No description available}")

      if $first_skill; then first_skill=false; else skills_json+=","; fi
      skills_json+="{\"name\":\"$skill_name\",\"desc\":\"$desc\"}"
    done
  fi
  skills_json+="]"

  # Collect agents with descriptions
  agents_json="["
  first_agent=true
  if [ -d "$version_dir/agents" ]; then
    for agent_file in "$version_dir/agents"/*.md "$version_dir/agents"/*.json; do
      [ -f "$agent_file" ] || continue
      agent_name=$(basename "$agent_file")
      agent_name="${agent_name%.md}"
      agent_name="${agent_name%.json}"

      desc=$(extract_description "$agent_file")
      desc=$(json_escape "${desc:-No description available}")

      if $first_agent; then first_agent=false; else agents_json+=","; fi
      agents_json+="{\"name\":\"$agent_name\",\"desc\":\"$desc\"}"
    done
    for agent_dir in "$version_dir/agents"/*/; do
      [ -d "$agent_dir" ] || continue
      agent_name=$(basename "$agent_dir")
      desc=""
      if [ -f "$agent_dir/AGENT.md" ]; then
        desc=$(extract_description "$agent_dir/AGENT.md")
      elif [ -f "$agent_dir/README.md" ]; then
        desc=$(grep -m1 -v '^#\|^$\|^---' "$agent_dir/README.md" 2>/dev/null | head -1)
      fi
      desc=$(json_escape "${desc:-No description available}")
      if $first_agent; then first_agent=false; else agents_json+=","; fi
      agents_json+="{\"name\":\"$agent_name\",\"desc\":\"$desc\"}"
    done
  fi
  if [ -d "$version_dir/agent-definitions" ]; then
    for agent_file in "$version_dir/agent-definitions"/*.json "$version_dir/agent-definitions"/*.md; do
      [ -f "$agent_file" ] || continue
      agent_name=$(basename "$agent_file")
      agent_name="${agent_name%.md}"
      agent_name="${agent_name%.json}"
      desc=$(extract_description "$agent_file")
      desc=$(json_escape "${desc:-No description available}")
      if $first_agent; then first_agent=false; else agents_json+=","; fi
      agents_json+="{\"name\":\"$agent_name\",\"desc\":\"$desc\"}"
    done
  fi
  agents_json+="]"

  if $FIRST_PLUGIN; then FIRST_PLUGIN=false; else PLUGIN_JSON+=","; fi
  PLUGIN_JSON+="\"$plugin_name\":{\"version\":\"$version\",\"skills\":$skills_json,\"agents\":$agents_json}"
done

PLUGIN_JSON+="}"

echo "Building Vibe Office..."

# Generate the HTML
cat > "$OUTPUT" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Vibe Office - Skill & Plugin HQ</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Press+Start+2P&family=Inter:wght@400;600;700&display=swap');

  :root {
    --bg: #0f0e17; --surface: #1a1a2e; --surface2: #232347;
    --accent1: #667eea; --accent2: #764ba2; --accent3: #f093fb;
    --green: #4ade80; --yellow: #fbbf24; --red: #f87171; --cyan: #22d3ee;
    --text: #e2e8f0; --text-dim: #94a3b8; --pixel-shadow: #0a0a14;
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Inter', sans-serif;
    overflow-x: hidden;
  }

  .header {
    background: linear-gradient(135deg, var(--surface) 0%, var(--surface2) 100%);
    border-bottom: 3px solid var(--accent1);
    padding: 20px 30px;
    display: flex; align-items: center; justify-content: space-between;
    position: sticky; top: 0; z-index: 100;
  }
  .header h1 {
    font-family: 'Press Start 2P', monospace;
    font-size: 18px;
    background: linear-gradient(90deg, var(--accent1), var(--accent3));
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
  }
  .header .stats {
    display: flex; gap: 20px; font-size: 12px; font-family: 'Press Start 2P', monospace;
  }
  .stat { display: flex; align-items: center; gap: 6px; }
  .stat .dot { width: 8px; height: 8px; border-radius: 2px; }
  .stat .dot.plugins { background: var(--accent1); }
  .stat .dot.skills { background: var(--green); }
  .stat .dot.agents { background: var(--yellow); }

  .search-bar {
    padding: 16px 30px;
    background: var(--surface);
    border-bottom: 1px solid #2a2a4a;
  }
  .search-bar input {
    width: 100%; padding: 10px 16px;
    background: var(--bg); border: 2px solid #334; border-radius: 8px;
    color: var(--text); font-size: 14px; outline: none;
    font-family: 'Press Start 2P', monospace; font-size: 10px;
  }
  .search-bar input:focus { border-color: var(--accent1); }
  .search-bar input::placeholder { color: var(--text-dim); }

  .office-floor {
    padding: 24px 30px;
    display: flex; flex-direction: column; gap: 24px;
  }

  .department {
    background: var(--surface);
    border: 2px solid #2a2a4a;
    border-radius: 12px;
    overflow: hidden;
    transition: border-color 0.3s;
  }
  .department:hover { border-color: var(--accent1); }
  .department.hidden { display: none; }

  .dept-header {
    padding: 16px 20px;
    display: flex; align-items: center; justify-content: space-between;
    cursor: pointer;
    background: linear-gradient(90deg, rgba(102,126,234,0.1), transparent);
    border-bottom: 1px solid #2a2a4a;
  }
  .dept-header:hover { background: linear-gradient(90deg, rgba(102,126,234,0.2), transparent); }

  .dept-left {
    display: flex; align-items: center; gap: 10px; flex: 1; min-width: 0;
  }
  .dept-name {
    font-family: 'Press Start 2P', monospace;
    font-size: 11px;
    display: flex; align-items: center; gap: 10px;
  }
  .dept-icon {
    width: 32px; height: 32px; min-width: 32px;
    display: flex; align-items: center; justify-content: center;
    font-size: 20px;
    background: var(--surface2); border-radius: 6px;
    border: 2px solid #3a3a5a;
    image-rendering: pixelated;
  }
  .dept-title-block { display: flex; flex-direction: column; gap: 4px; }
  .dept-desc {
    font-family: 'Inter', sans-serif;
    font-size: 11px;
    color: var(--text-dim);
    line-height: 1.4;
    max-width: 500px;
  }
  .dept-meta {
    display: flex; gap: 12px; font-size: 10px; color: var(--text-dim);
    font-family: 'Press Start 2P', monospace;
    align-items: center;
    flex-shrink: 0;
  }
  .dept-badge {
    padding: 2px 8px; border-radius: 4px;
    font-size: 8px; font-family: 'Press Start 2P', monospace;
  }
  .badge-skill { background: rgba(74,222,128,0.15); color: var(--green); }
  .badge-agent { background: rgba(251,191,36,0.15); color: var(--yellow); }

  .desk-grid {
    padding: 16px 20px;
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 10px;
  }
  .desk-grid.collapsed { display: none; }

  .desk {
    background: var(--bg);
    border: 2px solid #2a2a4a;
    border-radius: 8px;
    padding: 12px;
    display: flex; align-items: flex-start; gap: 10px;
    transition: all 0.2s;
    cursor: default;
    position: relative;
    overflow: hidden;
  }
  .desk:hover {
    border-color: var(--accent1);
    transform: translateY(-2px);
    box-shadow: 0 4px 12px rgba(102,126,234,0.2);
  }
  .desk.hidden { display: none; }

  .desk-avatar {
    width: 28px; height: 28px; min-width: 28px;
    display: flex; align-items: center; justify-content: center;
    border-radius: 4px;
    font-size: 14px;
    image-rendering: pixelated;
  }
  .desk-avatar.skill { background: rgba(74,222,128,0.15); }
  .desk-avatar.agent { background: rgba(251,191,36,0.15); }

  .desk-info { flex: 1; min-width: 0; }
  .desk-name {
    font-size: 10px;
    font-family: 'Press Start 2P', monospace;
    color: var(--text);
    word-break: break-word;
    line-height: 1.4;
  }
  .desk-desc {
    font-family: 'Inter', sans-serif;
    font-size: 11px;
    color: var(--text-dim);
    margin-top: 4px;
    line-height: 1.4;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .desk-type {
    font-size: 9px;
    margin-top: 4px;
    font-family: 'Press Start 2P', monospace;
  }
  .desk-type.skill-type { color: var(--green); }
  .desk-type.agent-type { color: var(--yellow); }

  .pixel-char {
    animation: float 3s ease-in-out infinite;
  }
  .pixel-char:nth-child(2n) { animation-delay: -1.5s; }

  @keyframes float {
    0%, 100% { transform: translateY(0); }
    50% { transform: translateY(-3px); }
  }

  .footer {
    padding: 20px 30px;
    text-align: center;
    font-family: 'Press Start 2P', monospace;
    font-size: 8px;
    color: var(--text-dim);
    border-top: 1px solid #2a2a4a;
  }

  .toggle-arrow {
    transition: transform 0.3s;
    font-size: 12px; color: var(--text-dim);
  }
  .toggle-arrow.collapsed { transform: rotate(-90deg); }

  .category-bar {
    padding: 10px 30px;
    display: flex; gap: 8px; flex-wrap: wrap;
  }
  .cat-btn {
    padding: 4px 12px; border-radius: 12px;
    font-family: 'Press Start 2P', monospace; font-size: 8px;
    border: 1px solid #3a3a5a; background: transparent;
    color: var(--text-dim); cursor: pointer; transition: all 0.2s;
  }
  .cat-btn:hover, .cat-btn.active {
    border-color: var(--accent1); color: var(--accent1);
    background: rgba(102,126,234,0.1);
  }

  /* Tooltip for full description on hover */
  .desk[title] { cursor: help; }
</style>
</head>
<body>

<div class="header">
  <h1>VIBE OFFICE</h1>
  <div class="stats">
    <div class="stat"><div class="dot plugins"></div><span id="pluginCount">0</span> DEPTS</div>
    <div class="stat"><div class="dot skills"></div><span id="skillCount">0</span> SKILLS</div>
    <div class="stat"><div class="dot agents"></div><span id="agentCount">0</span> AGENTS</div>
  </div>
</div>

<div class="search-bar">
  <input type="text" id="search" placeholder=">> SEARCH SKILLS & AGENTS...">
</div>

<div class="category-bar" id="categoryBar"></div>

<div class="office-floor" id="officeFloor"></div>

<div class="footer">
  VIBE OFFICE v1.1 // Auto-generated from ~/.claude/plugins
</div>

<script>
HTMLEOF

# Inject the dynamic plugin data
echo "const PLUGIN_DATA = (function() {" >> "$OUTPUT"
echo "  const raw = $PLUGIN_JSON;" >> "$OUTPUT"
cat >> "$OUTPUT" << 'JSEOF'
  const iconMap = {
    "databricks-tools": "&#x1F3ED;",
    "file-expenses": "&#x1F4B3;",
    "google-tools": "&#x1F4E7;",
    "internal-tools": "&#x1F50D;",
    "jira-tools": "&#x1F3AB;",
    "mcp-servers": "&#x1F50C;",
    "salesforce-tools": "&#x2601;",
    "specialized-agents": "&#x1F916;",
    "vibe-setup": "&#x2699;",
    "workflows": "&#x1F4CB;",
  };
  const deptDescriptions = {
    "databricks-tools": "Deploy, manage, and query Databricks workspaces, apps, dashboards, lakebase, and data resources",
    "file-expenses": "Analyze receipts, identify expenses, and file expense reports with Emburse ChromeRiver",
    "google-tools": "Full Google Workspace integration \u2014 Docs, Sheets, Slides, Drive, Calendar, Gmail, Tasks, Forms",
    "internal-tools": "Internal analytics, org lookups, Logfood queries, Aha ideas, engineering blockers, and jargon",
    "jira-tools": "Create, search, and manage JIRA tickets including ES engineering support tickets",
    "mcp-servers": "MCP server configurations for external tool connections (Slack, Chrome DevTools, etc.)",
    "salesforce-tools": "Read and update Salesforce CRM \u2014 UCOs, accounts, opportunities, blockers, and escalations",
    "specialized-agents": "Diagram generation (Mermaid, Lucid) and web dev loop testing with Chrome DevTools",
    "vibe-setup": "Configure, validate, update, and troubleshoot the Vibe environment and plugins",
    "workflows": "End-to-end workflows \u2014 POC docs, RFPs, competitive analysis, account reviews, training, and more",
  };
  for (const [name, data] of Object.entries(raw)) {
    data.icon = "&#x1F4E6;";
    data.description = "";
    for (const [key, icon] of Object.entries(iconMap)) {
      if (name.includes(key)) { data.icon = icon; break; }
    }
    for (const [key, desc] of Object.entries(deptDescriptions)) {
      if (name.includes(key)) { data.description = desc; break; }
    }
  }
  return raw;
})();
JSEOF

cat >> "$OUTPUT" << 'JSEOF'

const skillEmojis = {
  "databricks": "&#x1F9F1;", "google": "&#x1F4E8;", "gmail": "&#x1F4EC;",
  "salesforce": "&#x2601;", "jira": "&#x1F3AB;", "slack": "&#x1F4AC;",
  "auth": "&#x1F511;", "query": "&#x1F50E;", "deploy": "&#x1F680;",
  "diagram": "&#x1F4CA;", "expense": "&#x1F4B0;", "receipt": "&#x1F9FE;",
  "dashboard": "&#x1F4CA;", "data": "&#x1F4BE;", "learning": "&#x1F4DA;",
  "competitive": "&#x2694;", "sizing": "&#x1F4CF;", "rca": "&#x1F6A8;",
  "poc": "&#x1F3AF;", "rfp": "&#x1F4DD;", "security": "&#x1F6E1;",
  "performance": "&#x26A1;", "interview": "&#x1F3A4;", "humanize": "&#x270D;",
  "showcase": "&#x1F3AC;", "vibe": "&#x1F3B5;", "lineage": "&#x1F333;",
  "snowflake": "&#x2744;", "aha": "&#x1F4A1;", "escalation": "&#x1F6A9;",
  "calendar": "&#x1F4C5;", "sheets": "&#x1F4CA;", "slides": "&#x1F3AC;",
  "forms": "&#x1F4CB;", "tasks": "&#x2705;", "drive": "&#x1F4C1;",
  "docs": "&#x1F4C4;", "lakebase": "&#x1F4BE;", "apps": "&#x1F4F1;",
  "workspace": "&#x1F3E2;", "warehouse": "&#x1F3EA;", "blocker": "&#x1F6A7;",
  "org": "&#x1F3E2;", "jargon": "&#x1F4D6;", "troubleshoot": "&#x1F527;",
  "coach": "&#x1F3C6;", "transition": "&#x1F504;", "courses": "&#x1F393;",
  "account": "&#x1F464;", "support": "&#x1F4DE;",
};

function getEmoji(name) {
  for (const [key, emoji] of Object.entries(skillEmojis)) {
    if (name.toLowerCase().includes(key)) return emoji;
  }
  return "&#x1F4E6;";
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}

function render() {
  const floor = document.getElementById('officeFloor');
  const catBar = document.getElementById('categoryBar');
  let totalSkills = 0, totalAgents = 0, totalPlugins = 0;

  const cats = Object.keys(PLUGIN_DATA);
  catBar.innerHTML = '<button class="cat-btn active" onclick="filterCat(\'all\')">ALL</button>';
  cats.forEach(cat => {
    const d = PLUGIN_DATA[cat];
    if (d.skills.length + d.agents.length === 0) return;
    const label = cat.replace('fe-', '').replace(/-/g, ' ').toUpperCase();
    catBar.innerHTML += `<button class="cat-btn" data-cat="${cat}" onclick="filterCat('${cat}')">${label}</button>`;
  });

  floor.innerHTML = '';
  for (const [pluginName, data] of Object.entries(PLUGIN_DATA)) {
    if (data.skills.length + data.agents.length === 0) continue;
    totalPlugins++;
    totalSkills += data.skills.length;
    totalAgents += data.agents.length;

    const label = pluginName.replace('fe-', '').replace(/-/g, ' ').toUpperCase();
    const deptDesc = data.description ? `<div class="dept-desc">${escapeHtml(data.description)}</div>` : '';

    let desksHTML = '';
    data.skills.forEach(s => {
      const name = typeof s === 'object' ? s.name : s;
      const desc = typeof s === 'object' ? s.desc : '';
      const safeDesc = escapeHtml(desc);
      desksHTML += `
        <div class="desk" data-name="${name}" data-desc="${safeDesc}" title="${safeDesc}">
          <div class="desk-avatar skill pixel-char">${getEmoji(name)}</div>
          <div class="desk-info">
            <div class="desk-name">${escapeHtml(name)}</div>
            ${desc ? `<div class="desk-desc">${safeDesc}</div>` : ''}
            <div class="desk-type skill-type">SKILL</div>
          </div>
        </div>`;
    });
    data.agents.forEach(a => {
      const name = typeof a === 'object' ? a.name : a;
      const desc = typeof a === 'object' ? a.desc : '';
      const safeDesc = escapeHtml(desc);
      desksHTML += `
        <div class="desk" data-name="${name}" data-desc="${safeDesc}" title="${safeDesc}">
          <div class="desk-avatar agent pixel-char">${getEmoji(name)}</div>
          <div class="desk-info">
            <div class="desk-name">${escapeHtml(name)}</div>
            ${desc ? `<div class="desk-desc">${safeDesc}</div>` : ''}
            <div class="desk-type agent-type">AGENT</div>
          </div>
        </div>`;
    });

    floor.innerHTML += `
      <div class="department" data-plugin="${pluginName}">
        <div class="dept-header" onclick="toggleDept(this)">
          <div class="dept-left">
            <div class="dept-icon">${data.icon}</div>
            <div class="dept-title-block">
              <div class="dept-name">${label}</div>
              ${deptDesc}
            </div>
          </div>
          <div style="display:flex;align-items:center;gap:12px">
            <div class="dept-meta">
              <span class="dept-badge badge-skill">${data.skills.length} SKILLS</span>
              <span class="dept-badge badge-agent">${data.agents.length} AGENTS</span>
              <span style="color:var(--text-dim)">v${data.version}</span>
            </div>
            <span class="toggle-arrow">&#x25BC;</span>
          </div>
        </div>
        <div class="desk-grid">${desksHTML}</div>
      </div>`;
  }

  document.getElementById('pluginCount').textContent = totalPlugins;
  document.getElementById('skillCount').textContent = totalSkills;
  document.getElementById('agentCount').textContent = totalAgents;
}

function toggleDept(header) {
  const grid = header.nextElementSibling;
  const arrow = header.querySelector('.toggle-arrow');
  grid.classList.toggle('collapsed');
  arrow.classList.toggle('collapsed');
}

function filterCat(cat) {
  document.querySelectorAll('.cat-btn').forEach(b => b.classList.remove('active'));
  if (cat === 'all') {
    document.querySelector('.cat-btn').classList.add('active');
    document.querySelectorAll('.department').forEach(d => d.classList.remove('hidden'));
  } else {
    document.querySelector(`[data-cat="${cat}"]`).classList.add('active');
    document.querySelectorAll('.department').forEach(d => {
      d.classList.toggle('hidden', d.dataset.plugin !== cat);
    });
  }
}

document.getElementById('search').addEventListener('input', function() {
  const q = this.value.toLowerCase().trim();
  document.querySelectorAll('.department').forEach(dept => {
    let hasMatch = false;
    dept.querySelectorAll('.desk').forEach(desk => {
      const name = desk.dataset.name.toLowerCase();
      const desc = (desk.dataset.desc || '').toLowerCase();
      const match = !q || name.includes(q) || desc.includes(q);
      desk.classList.toggle('hidden', !match);
      if (match) hasMatch = true;
    });
    dept.classList.toggle('hidden', !hasMatch && q.length > 0);
    if (q.length > 0 && hasMatch) {
      dept.querySelector('.desk-grid').classList.remove('collapsed');
      dept.querySelector('.toggle-arrow').classList.remove('collapsed');
    }
  });
});

render();
</script>
</body>
</html>
JSEOF

echo ""
echo "Vibe Office generated at: $OUTPUT"
echo "Open it with: open $OUTPUT"
