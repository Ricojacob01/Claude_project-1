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
  # Look for directories containing plugin packages (those with skills/ or agents/ subdirs)
  for candidate in "$PLUGIN_BASE" "$PLUGIN_BASE"/*/; do
    if ls "$candidate"/*/latest/skills 2>/dev/null | head -1 > /dev/null 2>&1 || \
       ls "$candidate"/fe-*/*/skills 2>/dev/null | head -1 > /dev/null 2>&1; then
      PLUGIN_ROOT="$candidate"
      break
    fi
  done
  # Fallback: just use the cache dir
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

# Build JSON for each plugin
PLUGIN_JSON="{"
FIRST_PLUGIN=true

for plugin_dir in "$PLUGIN_ROOT"/*/; do
  [ -d "$plugin_dir" ] || continue
  plugin_name=$(basename "$plugin_dir")

  # Skip non-plugin directories
  [[ "$plugin_name" == "node_modules" || "$plugin_name" == ".git" ]] && continue

  # Find the version directory (must contain skills/ or agents/ to be a real plugin)
  version_dir=""
  version=""
  for vd in "$plugin_dir"/*/; do
    [ -d "$vd" ] || continue
    # A valid version dir has a skills/ or agents/ subdirectory
    if [ -d "$vd/skills" ] || [ -d "$vd/agents" ]; then
      v=$(basename "$vd")
      version_dir="$vd"
      version="$v"
      break
    fi
  done

  [ -z "$version_dir" ] && continue

  # Collect skills
  skills_json="["
  first_skill=true
  if [ -d "$version_dir/skills" ]; then
    for skill_dir in "$version_dir/skills"/*/; do
      [ -d "$skill_dir" ] || continue
      skill_name=$(basename "$skill_dir")
      if $first_skill; then first_skill=false; else skills_json+=","; fi
      skills_json+="\"$skill_name\""
    done
  fi
  skills_json+="]"

  # Collect agents (can be .md files, .json files, or subdirectories)
  agents_json="["
  first_agent=true
  if [ -d "$version_dir/agents" ]; then
    # Check for .md files (e.g., databricks-apps-developer.md)
    for agent_file in "$version_dir/agents"/*.md "$version_dir/agents"/*.json; do
      [ -f "$agent_file" ] || continue
      agent_name=$(basename "$agent_file")
      agent_name="${agent_name%.md}"
      agent_name="${agent_name%.json}"
      if $first_agent; then first_agent=false; else agents_json+=","; fi
      agents_json+="\"$agent_name\""
    done
    # Check for subdirectories
    for agent_dir in "$version_dir/agents"/*/; do
      [ -d "$agent_dir" ] || continue
      agent_name=$(basename "$agent_dir")
      if $first_agent; then first_agent=false; else agents_json+=","; fi
      agents_json+="\"$agent_name\""
    done
  fi
  # Also check agent-definitions/
  if [ -d "$version_dir/agent-definitions" ]; then
    for agent_file in "$version_dir/agent-definitions"/*.json "$version_dir/agent-definitions"/*.md; do
      [ -f "$agent_file" ] || continue
      agent_name=$(basename "$agent_file")
      agent_name="${agent_name%.md}"
      agent_name="${agent_name%.json}"
      if $first_agent; then first_agent=false; else agents_json+=","; fi
      agents_json+="\"$agent_name\""
    done
  fi
  agents_json+="]"

  # Skip plugins with no skills and no agents
  if [ "$skills_json" = "[]" ] && [ "$agents_json" = "[]" ]; then
    # Still include but mark as empty
    :
  fi

  if $FIRST_PLUGIN; then FIRST_PLUGIN=false; else PLUGIN_JSON+=","; fi
  PLUGIN_JSON+="\"$plugin_name\":{\"version\":\"$version\",\"skills\":$skills_json,\"agents\":$agents_json}"
done

PLUGIN_JSON+="}"

echo "Found plugins: $(echo "$PLUGIN_JSON" | grep -o '"fe-[^"]*"' | tr '\n' ' ')"

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

  /* === HEADER === */
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

  /* === SEARCH === */
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

  /* === OFFICE FLOOR === */
  .office-floor {
    padding: 24px 30px;
    display: flex; flex-direction: column; gap: 24px;
  }

  /* === DEPARTMENT (Plugin) === */
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

  .dept-name {
    font-family: 'Press Start 2P', monospace;
    font-size: 11px;
    display: flex; align-items: center; gap: 10px;
  }
  .dept-icon {
    width: 32px; height: 32px;
    display: flex; align-items: center; justify-content: center;
    font-size: 20px;
    background: var(--surface2); border-radius: 6px;
    border: 2px solid #3a3a5a;
    image-rendering: pixelated;
  }
  .dept-meta {
    display: flex; gap: 12px; font-size: 10px; color: var(--text-dim);
    font-family: 'Press Start 2P', monospace;
  }
  .dept-badge {
    padding: 2px 8px; border-radius: 4px;
    font-size: 8px; font-family: 'Press Start 2P', monospace;
  }
  .badge-skill { background: rgba(74,222,128,0.15); color: var(--green); }
  .badge-agent { background: rgba(251,191,36,0.15); color: var(--yellow); }

  /* === DESK GRID (Skills/Agents) === */
  .desk-grid {
    padding: 16px 20px;
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 10px;
  }
  .desk-grid.collapsed { display: none; }

  /* === DESK (Individual Skill/Agent) === */
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
  .desk-type {
    font-size: 9px;
    margin-top: 4px;
    font-family: 'Press Start 2P', monospace;
  }
  .desk-type.skill-type { color: var(--green); }
  .desk-type.agent-type { color: var(--yellow); }

  /* Pixel character animation */
  .pixel-char {
    animation: float 3s ease-in-out infinite;
  }
  .pixel-char:nth-child(2n) { animation-delay: -1.5s; }

  @keyframes float {
    0%, 100% { transform: translateY(0); }
    50% { transform: translateY(-3px); }
  }

  /* === FOOTER === */
  .footer {
    padding: 20px 30px;
    text-align: center;
    font-family: 'Press Start 2P', monospace;
    font-size: 8px;
    color: var(--text-dim);
    border-top: 1px solid #2a2a4a;
  }

  /* Toggle arrow */
  .toggle-arrow {
    transition: transform 0.3s;
    font-size: 12px; color: var(--text-dim);
  }
  .toggle-arrow.collapsed { transform: rotate(-90deg); }

  /* Category labels row */
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
  VIBE OFFICE v1.0 // Auto-generated from ~/.claude/plugins
</div>

<script>
HTMLEOF

# Inject the dynamic plugin data
echo "const PLUGIN_DATA = (function() {" >> "$OUTPUT"
echo "  const raw = $PLUGIN_JSON;" >> "$OUTPUT"
cat >> "$OUTPUT" << 'JSEOF'
  // Assign icons based on plugin name keywords
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
  for (const [name, data] of Object.entries(raw)) {
    data.icon = "&#x1F4E6;"; // default
    for (const [key, icon] of Object.entries(iconMap)) {
      if (name.includes(key)) { data.icon = icon; break; }
    }
  }
  return raw;
})();
JSEOF

# Append the rest of the JS
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

function render() {
  const floor = document.getElementById('officeFloor');
  const catBar = document.getElementById('categoryBar');
  let totalSkills = 0, totalAgents = 0, totalPlugins = 0;

  // Category buttons
  const cats = Object.keys(PLUGIN_DATA);
  catBar.innerHTML = '<button class="cat-btn active" onclick="filterCat(\'all\')">ALL</button>';
  cats.forEach(cat => {
    if (PLUGIN_DATA[cat].skills.length + PLUGIN_DATA[cat].agents.length === 0) return;
    const label = cat.replace('fe-', '').replace(/-/g, ' ').toUpperCase();
    catBar.innerHTML += `<button class="cat-btn" data-cat="${cat}" onclick="filterCat('${cat}')">${label}</button>`;
  });

  // Departments
  floor.innerHTML = '';
  for (const [pluginName, data] of Object.entries(PLUGIN_DATA)) {
    if (data.skills.length + data.agents.length === 0) continue;
    totalPlugins++;
    totalSkills += data.skills.length;
    totalAgents += data.agents.length;

    const label = pluginName.replace('fe-', '').replace(/-/g, ' ').toUpperCase();

    let desksHTML = '';
    data.skills.forEach(s => {
      desksHTML += `
        <div class="desk" data-name="${s}">
          <div class="desk-avatar skill pixel-char">${getEmoji(s)}</div>
          <div class="desk-info">
            <div class="desk-name">${s}</div>
            <div class="desk-type skill-type">SKILL</div>
          </div>
        </div>`;
    });
    data.agents.forEach(a => {
      desksHTML += `
        <div class="desk" data-name="${a}">
          <div class="desk-avatar agent pixel-char">${getEmoji(a)}</div>
          <div class="desk-info">
            <div class="desk-name">${a}</div>
            <div class="desk-type agent-type">AGENT</div>
          </div>
        </div>`;
    });

    floor.innerHTML += `
      <div class="department" data-plugin="${pluginName}">
        <div class="dept-header" onclick="toggleDept(this)">
          <div class="dept-name">
            <div class="dept-icon">${data.icon}</div>
            ${label}
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
      const match = !q || name.includes(q);
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
