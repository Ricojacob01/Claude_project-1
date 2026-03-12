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
    --orange: #fb923c;
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

  /* === TAB NAV === */
  .tab-nav {
    display: flex; gap: 0;
    background: var(--surface);
    border-bottom: 2px solid #2a2a4a;
  }
  .tab-btn {
    padding: 12px 24px;
    font-family: 'Press Start 2P', monospace; font-size: 10px;
    background: transparent; border: none; color: var(--text-dim);
    cursor: pointer; transition: all 0.2s;
    border-bottom: 3px solid transparent;
    position: relative;
  }
  .tab-btn:hover { color: var(--text); background: rgba(102,126,234,0.05); }
  .tab-btn.active {
    color: var(--accent1);
    border-bottom-color: var(--accent1);
    background: rgba(102,126,234,0.1);
  }
  .tab-btn .tab-badge {
    font-size: 7px; padding: 1px 5px; border-radius: 8px;
    margin-left: 6px; vertical-align: middle;
    background: var(--accent2); color: white;
  }
  .tab-content { display: none; }
  .tab-content.active { display: block; }

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
  .desk.draggable { cursor: grab; }
  .desk.draggable:active { cursor: grabbing; }
  .desk.dragging { opacity: 0.4; }

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

  .desk[title] { cursor: help; }

  /* ============================== */
  /* === AGENT LAB TAB STYLES === */
  /* ============================== */
  .agent-lab {
    padding: 24px 30px;
    display: flex; gap: 24px;
    min-height: calc(100vh - 200px);
  }

  /* Left panel: Agent type selector */
  .lab-sidebar {
    width: 300px; min-width: 300px;
    display: flex; flex-direction: column; gap: 12px;
  }
  .lab-section-title {
    font-family: 'Press Start 2P', monospace;
    font-size: 10px; color: var(--accent3);
    margin-bottom: 4px;
  }
  .agent-type-card {
    background: var(--surface);
    border: 2px solid #2a2a4a;
    border-radius: 10px;
    padding: 12px 14px;
    cursor: pointer;
    transition: all 0.2s;
  }
  .agent-type-card:hover { border-color: var(--accent1); }
  .agent-type-card.selected {
    border-color: var(--accent3);
    background: linear-gradient(135deg, rgba(102,126,234,0.15), rgba(240,147,251,0.1));
  }
  .agent-type-name {
    font-family: 'Press Start 2P', monospace;
    font-size: 9px; color: var(--text);
    display: flex; align-items: center; gap: 8px;
  }
  .agent-type-desc {
    font-size: 11px; color: var(--text-dim);
    margin-top: 6px; line-height: 1.4;
  }
  .agent-type-tools {
    margin-top: 8px;
    display: flex; flex-wrap: wrap; gap: 4px;
  }
  .tool-chip {
    font-size: 9px; padding: 2px 7px; border-radius: 6px;
    font-family: 'Press Start 2P', monospace;
  }
  .tool-chip.has { background: rgba(74,222,128,0.15); color: var(--green); }
  .tool-chip.no { background: rgba(248,113,113,0.15); color: var(--red); text-decoration: line-through; }

  /* Center: Workbench */
  .lab-workbench {
    flex: 1;
    display: flex; flex-direction: column; gap: 16px;
  }
  .workbench-header {
    display: flex; align-items: center; justify-content: space-between;
  }
  .workbench-title {
    font-family: 'Press Start 2P', monospace;
    font-size: 12px;
    background: linear-gradient(90deg, var(--accent1), var(--accent3));
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
  }

  /* Prompt builder */
  .prompt-builder {
    background: var(--surface);
    border: 2px solid #2a2a4a;
    border-radius: 12px;
    padding: 16px;
  }
  .prompt-label {
    font-family: 'Press Start 2P', monospace;
    font-size: 9px; color: var(--text-dim);
    margin-bottom: 8px;
  }
  .prompt-textarea {
    width: 100%; min-height: 80px; padding: 12px;
    background: var(--bg); border: 2px solid #334; border-radius: 8px;
    color: var(--text); font-family: 'Inter', sans-serif; font-size: 13px;
    resize: vertical; outline: none; line-height: 1.5;
  }
  .prompt-textarea:focus { border-color: var(--accent1); }
  .prompt-textarea::placeholder { color: var(--text-dim); }

  /* Assigned skills drop zone */
  .skill-dropzone {
    background: var(--surface);
    border: 2px dashed #3a3a5a;
    border-radius: 12px;
    padding: 16px;
    min-height: 120px;
    transition: all 0.3s;
  }
  .skill-dropzone.drag-over {
    border-color: var(--accent3);
    background: rgba(240,147,251,0.05);
  }
  .skill-dropzone.empty::after {
    content: 'Drag skills here from the skill palette below, or click skills to add them';
    display: block;
    text-align: center;
    padding: 24px;
    color: var(--text-dim);
    font-size: 11px;
    font-family: 'Press Start 2P', monospace;
    line-height: 1.8;
  }
  .assigned-skills {
    display: flex; flex-wrap: wrap; gap: 8px;
  }
  .assigned-chip {
    display: flex; align-items: center; gap: 6px;
    padding: 6px 10px;
    background: var(--bg);
    border: 2px solid var(--accent1);
    border-radius: 8px;
    font-size: 10px;
    font-family: 'Press Start 2P', monospace;
    color: var(--text);
    animation: popIn 0.2s ease-out;
  }
  .assigned-chip .remove-btn {
    cursor: pointer; color: var(--red);
    font-size: 12px; font-family: 'Inter', sans-serif;
    font-weight: 700;
    opacity: 0.7;
    transition: opacity 0.2s;
  }
  .assigned-chip .remove-btn:hover { opacity: 1; }
  @keyframes popIn {
    0% { transform: scale(0.8); opacity: 0; }
    100% { transform: scale(1); opacity: 1; }
  }

  /* Skill palette (bottom of workbench) */
  .skill-palette {
    background: var(--surface);
    border: 2px solid #2a2a4a;
    border-radius: 12px;
    padding: 16px;
  }
  .palette-header {
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 12px;
  }
  .palette-search {
    padding: 6px 12px;
    background: var(--bg); border: 1px solid #334; border-radius: 6px;
    color: var(--text); font-size: 11px; outline: none;
    font-family: 'Press Start 2P', monospace; font-size: 8px;
    width: 200px;
  }
  .palette-search:focus { border-color: var(--accent1); }
  .palette-grid {
    display: flex; flex-wrap: wrap; gap: 6px;
    max-height: 300px; overflow-y: auto;
  }
  .palette-chip {
    display: flex; align-items: center; gap: 5px;
    padding: 5px 10px;
    background: var(--bg);
    border: 1px solid #2a2a4a;
    border-radius: 6px;
    font-size: 10px;
    font-family: 'Press Start 2P', monospace;
    color: var(--text-dim);
    cursor: pointer;
    transition: all 0.2s;
    user-select: none;
  }
  .palette-chip:hover {
    border-color: var(--accent1); color: var(--text);
    transform: translateY(-1px);
  }
  .palette-chip.added {
    border-color: var(--green); color: var(--green);
    background: rgba(74,222,128,0.08);
  }
  .palette-chip .chip-emoji { font-size: 12px; }
  .palette-chip.is-agent { border-color: rgba(251,191,36,0.3); }
  .palette-chip.is-agent:hover { border-color: var(--yellow); color: var(--yellow); }
  .palette-chip.is-agent.added { border-color: var(--yellow); color: var(--yellow); background: rgba(251,191,36,0.08); }

  /* Generated command output */
  .command-output {
    background: var(--surface);
    border: 2px solid #2a2a4a;
    border-radius: 12px;
    padding: 16px;
    position: relative;
  }
  .command-code {
    background: var(--bg);
    border: 1px solid #334;
    border-radius: 8px;
    padding: 12px;
    font-family: 'Menlo', 'Monaco', 'Courier New', monospace;
    font-size: 12px;
    color: var(--green);
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 300px;
    overflow-y: auto;
    line-height: 1.6;
  }
  .command-code .kw { color: var(--accent3); }
  .command-code .str { color: var(--yellow); }
  .command-code .comment { color: var(--text-dim); }

  /* Action buttons */
  .lab-actions {
    display: flex; gap: 10px; flex-wrap: wrap;
  }
  .lab-btn {
    padding: 8px 18px;
    border: 2px solid; border-radius: 8px;
    font-family: 'Press Start 2P', monospace; font-size: 9px;
    cursor: pointer; transition: all 0.2s;
    display: flex; align-items: center; gap: 6px;
  }
  .lab-btn:hover { transform: translateY(-1px); }
  .lab-btn.primary {
    background: linear-gradient(135deg, var(--accent1), var(--accent2));
    border-color: var(--accent1); color: white;
  }
  .lab-btn.primary:hover { box-shadow: 0 4px 16px rgba(102,126,234,0.4); }
  .lab-btn.secondary {
    background: transparent;
    border-color: #3a3a5a; color: var(--text-dim);
  }
  .lab-btn.secondary:hover { border-color: var(--accent1); color: var(--text); }
  .lab-btn.danger {
    background: transparent;
    border-color: var(--red); color: var(--red);
  }

  /* Copy toast */
  .toast {
    position: fixed; bottom: 30px; right: 30px;
    padding: 12px 20px;
    background: var(--green); color: var(--bg);
    font-family: 'Press Start 2P', monospace; font-size: 9px;
    border-radius: 8px;
    transform: translateY(100px);
    opacity: 0;
    transition: all 0.3s;
    z-index: 1000;
  }
  .toast.show { transform: translateY(0); opacity: 1; }

  /* Tools legend */
  .tools-legend {
    display: flex; flex-wrap: wrap; gap: 4px;
    padding: 8px 0;
  }
  .tools-legend .tool-chip { font-size: 8px; }

  /* Bundled skills bar */
  .bundled-skills-bar {
    display: flex; flex-wrap: wrap; gap: 6px;
    padding: 10px 0;
  }
  .bundled-skill-chip {
    display: flex; align-items: center; gap: 5px;
    padding: 5px 10px;
    background: rgba(102,126,234,0.08);
    border: 1px solid rgba(102,126,234,0.3);
    border-radius: 6px;
    font-size: 10px;
    font-family: 'Press Start 2P', monospace;
    color: var(--accent1);
    cursor: help;
    transition: all 0.2s;
  }
  .bundled-skill-chip:hover {
    border-color: var(--accent1);
    background: rgba(102,126,234,0.15);
    transform: translateY(-1px);
  }
  .bundled-skill-chip .bsc-emoji { font-size: 12px; }
  .bundled-skill-chip .bsc-desc {
    font-family: 'Inter', sans-serif;
    font-size: 10px;
    color: var(--text-dim);
    max-width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .bundled-all-badge {
    padding: 5px 12px;
    background: rgba(240,147,251,0.08);
    border: 1px solid rgba(240,147,251,0.3);
    border-radius: 6px;
    font-size: 9px;
    font-family: 'Press Start 2P', monospace;
    color: var(--accent3);
  }

  /* Terminal / Activity Feed */
  .terminal-output {
    background: #0a0a14;
    border: 1px solid #334;
    border-radius: 8px;
    padding: 14px;
    max-height: 600px;
    overflow-y: auto;
    min-height: 120px;
  }

  .terminal-cursor {
    display: inline-block;
    width: 8px; height: 14px;
    background: var(--green);
    animation: blink 1s step-end infinite;
    vertical-align: text-bottom;
    margin-left: 4px;
  }
  @keyframes blink { 50% { opacity: 0; } }

  /* Activity events */
  .activity-event {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 8px 10px;
    border-radius: 8px;
    margin-bottom: 6px;
    animation: slideIn 0.25s ease-out;
  }
  @keyframes slideIn {
    0% { opacity: 0; transform: translateX(-10px); }
    100% { opacity: 1; transform: translateX(0); }
  }

  .activity-init {
    background: rgba(102,126,234,0.08);
    border-left: 3px solid var(--accent1);
  }
  .activity-text {
    background: rgba(226,232,240,0.05);
    border-left: 3px solid var(--text-dim);
  }
  .activity-tool {
    background: rgba(34,211,238,0.06);
    border-left: 3px solid var(--cyan);
  }
  .activity-result {
    background: rgba(74,222,128,0.08);
    border-left: 3px solid var(--green);
  }
  .activity-error {
    background: rgba(248,113,113,0.08);
    border-left: 3px solid var(--red);
  }

  .ae-icon {
    font-size: 16px;
    min-width: 24px;
    text-align: center;
    padding-top: 2px;
  }
  .ae-body { flex: 1; min-width: 0; }
  .ae-title {
    font-family: 'Press Start 2P', monospace;
    font-size: 9px;
    color: var(--text);
    margin-bottom: 3px;
  }
  .ae-tool-name {
    color: var(--cyan);
  }
  .ae-step {
    color: var(--text-dim);
    font-size: 8px;
    margin-left: 6px;
  }
  .ae-detail {
    font-family: 'Inter', sans-serif;
    font-size: 12px;
    color: var(--text-dim);
    line-height: 1.4;
    word-break: break-word;
  }
  .ae-message {
    font-family: 'Inter', sans-serif;
    font-size: 13px;
    color: var(--text);
    line-height: 1.6;
    white-space: pre-wrap;
    word-break: break-word;
  }

  /* Spinner for in-progress tools */
  .ae-spinner {
    width: 16px; height: 16px; min-width: 16px;
    border: 2px solid var(--cyan);
    border-top-color: transparent;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    margin-top: 3px;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  .ae-done {
    font-size: 14px;
    min-width: 16px;
    text-align: center;
    margin-top: 2px;
  }

  /* Agent status badge */
  .agent-status-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 8px;
    font-family: 'Press Start 2P', monospace;
    margin-left: 8px;
  }
  .agent-status-badge.starting { background: rgba(251,191,36,0.2); color: var(--yellow); }
  .agent-status-badge.running { background: rgba(34,211,238,0.2); color: var(--cyan); }
  .agent-status-badge.done { background: rgba(74,222,128,0.2); color: var(--green); }
  .agent-status-badge.error { background: rgba(248,113,113,0.2); color: var(--red); }
  .agent-status-badge.stopped { background: rgba(148,163,184,0.2); color: var(--text-dim); }

  /* History items */
  .history-item {
    background: var(--surface);
    border: 1px solid #2a2a4a;
    border-radius: 8px;
    padding: 10px 14px;
    margin-bottom: 8px;
    display: flex; align-items: center; justify-content: space-between;
    font-size: 11px;
  }
  .history-item .hi-prompt {
    font-family: 'Inter', sans-serif;
    color: var(--text-dim);
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin: 0 12px;
  }
  .history-item .hi-status {
    font-family: 'Press Start 2P', monospace;
    font-size: 8px;
  }

  /* Multi-agent panels */
  .agent-panel {
    background: var(--surface);
    border: 2px solid #2a2a4a;
    border-radius: 12px;
    overflow: hidden;
    transition: border-color 0.3s;
  }
  .agent-panel.is-running { border-color: var(--cyan); }
  .agent-panel.is-done { border-color: var(--green); opacity: 0.85; }
  .agent-panel.is-error { border-color: var(--red); }
  .agent-panel.is-stopped { border-color: var(--text-dim); opacity: 0.7; }

  .agent-panel-header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 10px 14px;
    background: linear-gradient(90deg, rgba(34,211,238,0.08), transparent);
    border-bottom: 1px solid #2a2a4a;
    cursor: pointer;
  }
  .agent-panel-header:hover { background: linear-gradient(90deg, rgba(34,211,238,0.12), transparent); }

  .ap-left {
    display: flex; align-items: center; gap: 8px;
    flex: 1; min-width: 0;
  }
  .ap-avatar {
    width: 28px; height: 28px; min-width: 28px;
    display: flex; align-items: center; justify-content: center;
    border-radius: 6px;
    font-size: 14px;
    background: rgba(34,211,238,0.12);
  }
  .ap-name {
    font-family: 'Press Start 2P', monospace;
    font-size: 9px; color: var(--text);
  }
  .ap-prompt-preview {
    font-family: 'Inter', sans-serif;
    font-size: 11px; color: var(--text-dim);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    max-width: 300px;
  }
  .ap-right {
    display: flex; align-items: center; gap: 8px;
    flex-shrink: 0;
  }
  .ap-toggle {
    font-size: 10px; color: var(--text-dim);
    transition: transform 0.3s;
  }
  .ap-toggle.collapsed { transform: rotate(-90deg); }

  .agent-panel-body {
    padding: 12px;
  }
  .agent-panel-body.collapsed { display: none; }

  /* Create Agent Modal */
  .modal-overlay {
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.7);
    display: flex; align-items: center; justify-content: center;
    z-index: 1000;
    animation: fadeIn 0.2s ease-out;
  }
  @keyframes fadeIn { 0% { opacity: 0; } 100% { opacity: 1; } }

  .modal {
    background: var(--surface);
    border: 2px solid var(--accent1);
    border-radius: 16px;
    width: 700px; max-width: 90vw; max-height: 85vh;
    overflow-y: auto;
    padding: 24px;
    animation: modalSlide 0.25s ease-out;
  }
  @keyframes modalSlide {
    0% { opacity: 0; transform: translateY(20px); }
    100% { opacity: 1; transform: translateY(0); }
  }

  .modal-title {
    font-family: 'Press Start 2P', monospace;
    font-size: 12px;
    background: linear-gradient(90deg, var(--accent1), var(--accent3));
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    margin-bottom: 20px;
  }

  .modal-field { margin-bottom: 16px; }
  .modal-field label {
    display: block;
    font-family: 'Press Start 2P', monospace;
    font-size: 8px; color: var(--text-dim);
    margin-bottom: 6px;
  }
  .modal-field input, .modal-field textarea {
    width: 100%; padding: 10px 14px;
    background: var(--bg); border: 2px solid #334; border-radius: 8px;
    color: var(--text); font-family: 'Inter', sans-serif; font-size: 13px;
    outline: none; line-height: 1.5;
  }
  .modal-field input:focus, .modal-field textarea:focus { border-color: var(--accent1); }
  .modal-field textarea { min-height: 60px; resize: vertical; }

  .modal-field .modal-hint {
    font-size: 11px; color: var(--text-dim); margin-top: 4px;
    font-family: 'Inter', sans-serif;
  }

  /* Skill picker inside modal */
  .modal-skill-picker {
    display: flex; flex-wrap: wrap; gap: 6px;
    max-height: 250px; overflow-y: auto;
    padding: 8px;
    background: var(--bg);
    border: 2px solid #334;
    border-radius: 8px;
  }
  .modal-skill-chip {
    display: flex; align-items: center; gap: 5px;
    padding: 5px 10px;
    background: var(--surface);
    border: 1px solid #2a2a4a;
    border-radius: 6px;
    font-size: 10px;
    font-family: 'Press Start 2P', monospace;
    color: var(--text-dim);
    cursor: pointer;
    transition: all 0.2s;
  }
  .modal-skill-chip:hover {
    border-color: var(--accent1); color: var(--text);
  }
  .modal-skill-chip.selected {
    border-color: var(--green); color: var(--green);
    background: rgba(74,222,128,0.08);
  }
  .modal-skill-chip .msc-emoji { font-size: 12px; }

  .modal-skill-search {
    width: 100%; padding: 8px 12px;
    background: var(--bg); border: 1px solid #334; border-radius: 6px;
    color: var(--text); font-size: 11px; outline: none;
    font-family: 'Press Start 2P', monospace; font-size: 8px;
    margin-bottom: 8px;
  }
  .modal-skill-search:focus { border-color: var(--accent1); }

  .modal-actions {
    display: flex; gap: 10px; justify-content: flex-end;
    margin-top: 20px;
    padding-top: 16px;
    border-top: 1px solid #2a2a4a;
  }

  /* Custom agent badge */
  .custom-badge {
    font-size: 7px; padding: 1px 5px; border-radius: 8px;
    background: var(--accent3); color: white;
    margin-left: 6px; vertical-align: middle;
    font-family: 'Press Start 2P', monospace;
  }

  .agent-type-card .custom-action-btn {
    width: 28px; height: 28px;
    display: inline-flex; align-items: center; justify-content: center;
    border-radius: 6px;
    font-size: 16px;
    cursor: pointer;
    opacity: 0.7;
    transition: all 0.2s;
    border: 1px solid transparent;
  }
  .agent-type-card .custom-action-btn:hover { opacity: 1; transform: scale(1.1); }
  .agent-type-card .custom-action-btn.edit-btn {
    color: var(--accent1);
  }
  .agent-type-card .custom-action-btn.edit-btn:hover {
    background: rgba(102,126,234,0.15);
    border-color: var(--accent1);
  }
  .agent-type-card .custom-action-btn.delete-btn {
    color: var(--red);
  }
  .agent-type-card .custom-action-btn.delete-btn:hover {
    background: rgba(248,113,113,0.15);
    border-color: var(--red);
  }

  /* ============================== */
  /* === WORKFLOWS TAB STYLES === */
  /* ============================== */
  .workflows-container {
    padding: 24px 30px;
    display: flex; gap: 24px;
    min-height: calc(100vh - 200px);
  }

  .wf-sidebar {
    width: 280px; min-width: 280px;
    display: flex; flex-direction: column; gap: 12px;
  }

  .wf-card {
    background: var(--surface);
    border: 2px solid #2a2a4a;
    border-radius: 10px;
    padding: 12px 14px;
    cursor: pointer;
    transition: all 0.2s;
  }
  .wf-card:hover { border-color: var(--accent1); }
  .wf-card.selected {
    border-color: var(--orange);
    background: linear-gradient(135deg, rgba(251,146,60,0.12), rgba(240,147,251,0.06));
  }
  .wf-card-name {
    font-family: 'Press Start 2P', monospace;
    font-size: 9px; color: var(--text);
    display: flex; align-items: center; gap: 8px;
  }
  .wf-card-desc {
    font-size: 11px; color: var(--text-dim);
    margin-top: 6px; line-height: 1.4;
  }
  .wf-card-steps {
    margin-top: 6px; font-size: 8px;
    font-family: 'Press Start 2P', monospace;
    color: var(--orange);
  }

  .wf-main {
    flex: 1;
    display: flex; flex-direction: column; gap: 16px;
  }

  /* Pipeline canvas with grid background */
  .pipeline-canvas {
    position: relative;
    background:
      radial-gradient(circle at 1px 1px, rgba(102,126,234,0.08) 1px, transparent 0);
    background-size: 24px 24px;
    border: 2px solid #2a2a4a;
    border-radius: 16px;
    padding: 32px 40px;
    min-height: 300px;
  }

  .pipeline-builder {
    display: flex; flex-direction: column;
    align-items: center;
    gap: 0;
  }

  /* Node card (n8n style) */
  .pipeline-node {
    width: 520px;
    background: var(--surface);
    border: 2px solid #3a3a5a;
    border-radius: 16px;
    overflow: hidden;
    transition: all 0.3s;
    position: relative;
    box-shadow: 0 4px 16px rgba(0,0,0,0.3);
  }
  .pipeline-node:hover { border-color: var(--accent1); box-shadow: 0 6px 24px rgba(102,126,234,0.2); }
  .pipeline-node.active-step {
    border-color: var(--cyan);
    box-shadow: 0 0 30px rgba(34,211,238,0.25), 0 6px 24px rgba(0,0,0,0.3);
    animation: nodeGlow 2s ease-in-out infinite;
  }
  @keyframes nodeGlow {
    0%, 100% { box-shadow: 0 0 20px rgba(34,211,238,0.2), 0 6px 24px rgba(0,0,0,0.3); }
    50% { box-shadow: 0 0 40px rgba(34,211,238,0.35), 0 6px 24px rgba(0,0,0,0.3); }
  }
  .pipeline-node.done-step { border-color: var(--green); }
  .pipeline-node.error-step { border-color: var(--red); }

  /* Node top bar with number + agent icon */
  .node-topbar {
    display: flex; align-items: center; justify-content: space-between;
    padding: 10px 16px;
    background: linear-gradient(90deg, rgba(102,126,234,0.12), rgba(118,75,162,0.08));
    border-bottom: 1px solid #2a2a4a;
  }
  .node-topbar-left {
    display: flex; align-items: center; gap: 10px;
  }
  .node-number {
    width: 30px; height: 30px; min-width: 30px;
    display: flex; align-items: center; justify-content: center;
    border-radius: 50%;
    background: linear-gradient(135deg, var(--accent1), var(--accent2));
    font-family: 'Press Start 2P', monospace;
    font-size: 10px; color: white;
    box-shadow: 0 2px 8px rgba(102,126,234,0.4);
  }
  .node-name-input {
    padding: 4px 8px;
    background: transparent; border: 1px solid transparent; border-radius: 6px;
    color: var(--text); font-family: 'Press Start 2P', monospace;
    font-size: 10px; outline: none;
    transition: all 0.2s;
    max-width: 200px;
  }
  .node-name-input:hover { border-color: #3a3a5a; }
  .node-name-input:focus { border-color: var(--accent1); background: var(--bg); }

  .node-topbar-right {
    display: flex; align-items: center; gap: 6px;
  }

  /* Input/output port dots */
  .node-port {
    width: 14px; height: 14px;
    border-radius: 50%;
    border: 2px solid #3a3a5a;
    background: var(--surface);
    position: absolute;
    left: 50%; transform: translateX(-50%);
    z-index: 2;
    transition: all 0.3s;
  }
  .node-port.input-port { top: -8px; }
  .node-port.output-port { bottom: -8px; }
  .node-port.active { border-color: var(--cyan); background: var(--cyan); box-shadow: 0 0 8px rgba(34,211,238,0.5); }
  .node-port.done { border-color: var(--green); background: var(--green); }

  /* Node body */
  .node-body {
    padding: 14px 16px;
  }

  /* Agent selector inside node */
  .node-agent-row {
    display: flex; align-items: center; gap: 8px;
    margin-bottom: 10px;
  }
  .node-agent-select {
    flex: 1;
    padding: 6px 10px;
    background: var(--bg); border: 1px solid #334; border-radius: 8px;
    color: var(--text); font-family: 'Inter', sans-serif; font-size: 12px;
    outline: none; cursor: pointer;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' fill='%2394a3b8'%3E%3Cpath d='M2 4l4 4 4-4'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 10px center;
    padding-right: 30px;
  }
  .node-agent-select:focus { border-color: var(--accent1); }
  .node-agent-label {
    font-family: 'Press Start 2P', monospace;
    font-size: 7px; color: var(--text-dim);
    white-space: nowrap;
  }

  .node-prompt {
    width: 100%; min-height: 56px; padding: 10px;
    background: var(--bg); border: 1px solid #334; border-radius: 8px;
    color: var(--text); font-family: 'Inter', sans-serif; font-size: 13px;
    resize: vertical; outline: none; line-height: 1.5;
  }
  .node-prompt:focus { border-color: var(--accent1); }
  .node-prompt::placeholder { color: var(--text-dim); }

  /* Skills & agents bar inside node */
  .node-extras {
    margin-top: 10px;
  }
  .node-extras summary {
    cursor: pointer;
    font-family: 'Press Start 2P', monospace;
    font-size: 7px; color: var(--text-dim);
    user-select: none;
    padding: 4px 0;
  }
  .node-extras-content {
    display: flex; flex-wrap: wrap; gap: 4px;
    margin-top: 6px;
    max-height: 150px; overflow-y: auto;
  }
  .node-skill-toggle {
    display: flex; align-items: center; gap: 4px;
    padding: 3px 8px;
    background: var(--bg);
    border: 1px solid #2a2a4a;
    border-radius: 4px;
    font-size: 9px;
    font-family: 'Press Start 2P', monospace;
    color: var(--text-dim);
    cursor: pointer;
    transition: all 0.2s;
  }
  .node-skill-toggle:hover { border-color: var(--accent1); color: var(--text); }
  .node-skill-toggle.active {
    border-color: var(--green); color: var(--green);
    background: rgba(74,222,128,0.08);
  }

  /* Connector line between nodes */
  .pipeline-wire {
    display: flex; flex-direction: column;
    align-items: center;
    padding: 0;
    height: 40px;
    position: relative;
  }
  .wire-line {
    width: 2px;
    flex: 1;
    background: linear-gradient(180deg, #3a3a5a, #3a3a5a);
    transition: background 0.3s;
  }
  .wire-arrow {
    width: 0; height: 0;
    border-left: 6px solid transparent;
    border-right: 6px solid transparent;
    border-top: 8px solid #3a3a5a;
    transition: border-color 0.3s;
  }
  .pipeline-wire.active .wire-line {
    background: linear-gradient(180deg, var(--cyan), var(--cyan));
    box-shadow: 0 0 8px rgba(34,211,238,0.3);
  }
  .pipeline-wire.active .wire-arrow { border-top-color: var(--cyan); }
  .pipeline-wire.done .wire-line {
    background: linear-gradient(180deg, var(--green), var(--green));
  }
  .pipeline-wire.done .wire-arrow { border-top-color: var(--green); }

  /* Data flow label on wire */
  .wire-label {
    position: absolute;
    left: calc(50% + 14px);
    top: 50%; transform: translateY(-50%);
    font-family: 'Press Start 2P', monospace;
    font-size: 6px;
    color: var(--text-dim);
    background: var(--bg);
    padding: 2px 6px;
    border-radius: 4px;
    border: 1px solid #2a2a4a;
    white-space: nowrap;
  }

  .step-remove {
    width: 28px; height: 28px;
    display: flex; align-items: center; justify-content: center;
    border-radius: 6px; border: 1px solid transparent;
    color: var(--red); cursor: pointer; font-size: 16px;
    opacity: 0.6; transition: all 0.2s;
  }
  .step-remove:hover {
    opacity: 1; background: rgba(248,113,113,0.15);
    border-color: var(--red);
  }

  /* Step status during execution */
  .step-status-indicator {
    display: none;
    align-items: center; gap: 8px;
    margin-top: 10px;
    padding: 8px 12px;
    border-radius: 8px;
    font-size: 11px;
    font-family: 'Inter', sans-serif;
  }
  .step-status-indicator.visible { display: flex; }
  .step-status-indicator.running {
    background: rgba(34,211,238,0.08);
    color: var(--cyan);
  }
  .step-status-indicator.complete {
    background: rgba(74,222,128,0.08);
    color: var(--green);
  }
  .step-status-indicator.error {
    background: rgba(248,113,113,0.08);
    color: var(--red);
  }

  /* Step terminal (activity feed per step) */
  .step-terminal {
    display: none;
    margin-top: 10px;
    max-height: 300px;
    overflow-y: auto;
    background: #0a0a14;
    border: 1px solid #334;
    border-radius: 8px;
    padding: 10px;
  }
  .step-terminal.visible { display: block; }

  /* Responsive */
  @media (max-width: 900px) {
    .agent-lab { flex-direction: column; }
    .lab-sidebar { width: 100%; min-width: 0; }
    .workflows-container { flex-direction: column; }
    .wf-sidebar { width: 100%; min-width: 0; }
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

<!-- Tab Navigation -->
<div class="tab-nav">
  <button class="tab-btn active" onclick="switchTab('office')">OFFICE</button>
  <button class="tab-btn" onclick="switchTab('lab')">AGENT LAB</button>
  <button class="tab-btn" onclick="switchTab('workflows')">WORKFLOWS<span class="tab-badge">NEW</span></button>
</div>

<!-- TAB 1: Office (existing) -->
<div class="tab-content active" id="tab-office">
  <div class="search-bar">
    <input type="text" id="search" placeholder=">> SEARCH SKILLS & AGENTS...">
  </div>
  <div class="category-bar" id="categoryBar"></div>
  <div class="office-floor" id="officeFloor"></div>
</div>

<!-- TAB 2: Agent Lab -->
<div class="tab-content" id="tab-lab">
  <div class="agent-lab">
    <!-- Left: Agent type selector -->
    <div class="lab-sidebar">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">
        <div class="lab-section-title">SELECT AGENT TYPE</div>
        <button class="lab-btn primary" onclick="openCreateAgentModal()" style="padding:4px 10px;font-size:7px">+ CREATE</button>
      </div>
      <div id="agentTypeList"></div>
    </div>

    <!-- Create Agent Modal (hidden) -->
    <div class="modal-overlay" id="createAgentModal" style="display:none" onclick="if(event.target===this)closeCreateAgentModal()">
      <div class="modal">
        <div class="modal-title">CREATE CUSTOM AGENT</div>

        <div class="modal-field">
          <label>AGENT NAME</label>
          <input type="text" id="customAgentName" placeholder="e.g., Data Pipeline Expert">
          <div class="modal-hint">A short, descriptive name for your agent</div>
        </div>

        <div class="modal-field">
          <label>EMOJI ICON</label>
          <input type="text" id="customAgentEmoji" placeholder="e.g., &#x1F680;" style="width:80px">
        </div>

        <div class="modal-field">
          <label>DESCRIPTION</label>
          <textarea id="customAgentDesc" placeholder="What does this agent specialize in? What kind of tasks should it handle?"></textarea>
        </div>

        <div class="modal-field">
          <label>SYSTEM INSTRUCTIONS <span style="color:var(--text-dim);font-family:Inter;font-size:11px">(optional — extra context prepended to every prompt)</span></label>
          <textarea id="customAgentInstructions" placeholder="e.g., You are an expert in building ETL pipelines with Databricks. Always follow best practices for Delta Lake..." style="min-height:80px"></textarea>
        </div>

        <div class="modal-field">
          <label>ASSIGNED SKILLS <span style="color:var(--text-dim);font-family:Inter;font-size:11px">(select skills this agent should use)</span></label>
          <input type="text" class="modal-skill-search" id="modalSkillSearch" placeholder="FILTER SKILLS...">
          <div class="modal-skill-picker" id="modalSkillPicker"></div>
        </div>

        <div class="modal-actions">
          <button class="lab-btn secondary" onclick="closeCreateAgentModal()">CANCEL</button>
          <button class="lab-btn primary" id="modalSaveBtn" onclick="saveCustomAgent()">&#x2728; CREATE AGENT</button>
        </div>
      </div>
    </div>

    <!-- Center: Workbench -->
    <div class="lab-workbench">
      <div class="workbench-header">
        <div class="workbench-title" id="workbenchTitle">CONFIGURE YOUR AGENT</div>
      </div>

      <!-- What tools this agent gets -->
      <div style="margin-bottom:4px">
        <div class="prompt-label">TOOLS THIS AGENT GETS</div>
        <div class="tools-legend" id="toolsLegend"></div>
      </div>

      <!-- Bundled skills this agent comes with -->
      <div id="bundledSkillsSection" style="display:none; margin-bottom:4px">
        <div class="prompt-label">BUNDLED SKILLS <span style="color:var(--text-dim);font-family:Inter;font-size:11px">(skills this agent comes with)</span></div>
        <div class="bundled-skills-bar" id="bundledSkillsBar"></div>
      </div>

      <!-- Task / Prompt -->
      <div class="prompt-builder">
        <div class="prompt-label">TASK PROMPT</div>
        <textarea class="prompt-textarea" id="taskPrompt" placeholder="Describe what you want the agent to do..."></textarea>
      </div>

      <!-- Assigned Skills -->
      <div>
        <div class="prompt-label" style="margin-bottom:8px">ASSIGNED SKILLS <span style="color:var(--text-dim);font-family:Inter;font-size:11px">(context passed to the agent)</span></div>
        <div class="skill-dropzone empty" id="skillDropzone">
          <div class="assigned-skills" id="assignedSkills"></div>
        </div>
      </div>

      <!-- Skill Palette -->
      <div class="skill-palette">
        <div class="palette-header">
          <div class="prompt-label" style="margin:0">SKILL PALETTE</div>
          <input type="text" class="palette-search" id="paletteSearch" placeholder="FILTER...">
        </div>
        <div class="palette-grid" id="paletteGrid"></div>
      </div>

      <!-- Actions -->
      <div class="lab-actions">
        <button class="lab-btn primary" onclick="launchAgent()" id="launchBtn">&#x1F680; LAUNCH AGENT</button>
        <button class="lab-btn secondary" onclick="saveCurrentAsAgent()" title="Save current config as a reusable custom agent">&#x1F4BE; SAVE AS AGENT</button>
        <button class="lab-btn secondary" onclick="generateCommand()">PREVIEW COMMAND</button>
        <button class="lab-btn secondary" onclick="copyCommand()">COPY TO CLIPBOARD</button>
        <button class="lab-btn danger" onclick="clearLab()">CLEAR</button>
      </div>

      <!-- Server status -->
      <div id="serverStatus" style="display:none; padding:8px 14px; border-radius:8px; font-family:'Press Start 2P',monospace; font-size:8px; margin-bottom:8px;">
      </div>

      <!-- Generated Command -->
      <div class="command-output" id="commandOutput" style="display:none">
        <div class="prompt-label">GENERATED COMMAND</div>
        <div class="command-code" id="commandCode"></div>
      </div>

      <!-- Running Agents Container -->
      <div id="runningAgentsSection" style="display:none">
        <div class="prompt-label" style="margin-bottom:10px">RUNNING AGENTS <span id="runningCount" style="color:var(--cyan)"></span></div>
        <div id="agentPanels" style="display:flex;flex-direction:column;gap:12px"></div>
      </div>

      <!-- Agent History -->
      <div id="agentHistory" style="display:none">
        <div class="prompt-label" style="margin-bottom:8px">COMPLETED AGENTS</div>
        <div id="historyList"></div>
      </div>
    </div>
  </div>
</div>

<!-- TAB 3: Workflows -->
<div class="tab-content" id="tab-workflows">
  <div class="workflows-container">
    <!-- Left: Saved workflows -->
    <div class="wf-sidebar">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">
        <div class="lab-section-title" style="color:var(--orange)">WORKFLOWS</div>
        <button class="lab-btn primary" onclick="newWorkflow()" style="padding:4px 10px;font-size:7px">+ NEW</button>
      </div>
      <div id="wfList"></div>
    </div>

    <!-- Right: Pipeline builder -->
    <div class="wf-main">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">
        <div>
          <input type="text" id="wfName" placeholder="Workflow name..." style="background:transparent;border:none;font-family:'Press Start 2P',monospace;font-size:14px;color:var(--orange);outline:none;width:400px">
          <div style="font-size:11px;color:var(--text-dim);font-family:Inter;margin-top:4px">
            Each step's output feeds into the next as context. Assign agents &amp; skills per step.
          </div>
        </div>
        <div class="lab-actions" style="margin:0">
          <button class="lab-btn primary" onclick="runWorkflow()" id="runWfBtn" style="background:linear-gradient(135deg,var(--orange),var(--accent2))">&#x25B6; RUN</button>
          <button class="lab-btn secondary" onclick="saveWorkflow()">&#x1F4BE; SAVE</button>
          <button class="lab-btn danger" onclick="clearWorkflow()">CLEAR</button>
        </div>
      </div>

      <!-- Pipeline canvas -->
      <div class="pipeline-canvas">
        <div class="pipeline-builder" id="pipelineBuilder">
          <!-- Nodes injected by JS -->
        </div>

        <div style="display:flex;justify-content:center;margin-top:16px">
          <button class="lab-btn secondary" onclick="addPipelineStep()" style="font-size:8px;border-style:dashed">+ ADD STEP</button>
        </div>
      </div>

      <!-- Workflow execution log -->
      <div id="wfExecutionStatus" style="display:none">
        <div class="prompt-label" style="margin-bottom:8px">EXECUTION LOG</div>
        <div class="terminal-output" id="wfTerminal" style="max-height:400px"></div>
      </div>
    </div>
  </div>
</div>

<div class="footer">
  VIBE OFFICE v3.0 // Auto-generated from ~/.claude/plugins
</div>

<div class="toast" id="toast">COPIED!</div>

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

// =============================================
// AGENT TYPE DEFINITIONS (from Claude Code)
// =============================================
const AGENT_TYPES = [
  {
    id: "general-purpose",
    name: "General Purpose",
    emoji: "&#x1F9E0;",
    desc: "Full-powered agent for complex multi-step tasks. Has access to ALL tools.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "Explore",
    name: "Explore",
    emoji: "&#x1F50D;",
    desc: "Fast codebase exploration. Find files, search code, answer questions about architecture.",
    tools: ["Bash","Read","Glob","Grep","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: ["Agent","Edit","Write","NotebookEdit"]
  },
  {
    id: "Plan",
    name: "Plan",
    emoji: "&#x1F4D0;",
    desc: "Software architect for designing implementation plans. Returns step-by-step strategies.",
    tools: ["Bash","Read","Glob","Grep","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: ["Agent","Edit","Write","NotebookEdit"]
  },
  {
    id: "fe-databricks-tools:databricks-apps-developer",
    name: "Databricks Apps Dev",
    emoji: "&#x1F4F1;",
    desc: "Expert Databricks Apps developer. Scaffolds, configures, deploys, and manages apps.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "fe-internal-tools:field-data-analyst",
    name: "Field Data Analyst",
    emoji: "&#x1F4CA;",
    desc: "Expert data analyst for Salesforce, Logfood, and organizational queries.",
    tools: ["Bash","Read","Grep","Glob","Write","Edit","Skill"],
    excluded: ["Agent","WebSearch","WebFetch"]
  },
  {
    id: "fe-google-tools:google-drive",
    name: "Google Drive",
    emoji: "&#x1F4C1;",
    desc: "Manages Google Drive/Docs/Slides. Opens, reads, creates, edits documents.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "fe-jira-tools:jira-ticket-assistant",
    name: "JIRA Assistant",
    emoji: "&#x1F3AB;",
    desc: "Creates, searches, and manages JIRA tickets and ES engineering support tickets.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "fe-specialized-agents:mermaid-diagrams",
    name: "Mermaid Diagrams",
    emoji: "&#x1F4CA;",
    desc: "Generates Mermaid diagrams and renders them as PNG, SVG, or PDF images.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "fe-specialized-agents:web-devloop-tester",
    name: "Web DevLoop Tester",
    emoji: "&#x1F310;",
    desc: "Starts dev servers, tests UI changes, verifies functionality with Chrome DevTools.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "fe-workflows:sqrc-validator",
    name: "SQRC Validator",
    emoji: "&#x2705;",
    desc: "Validates security questionnaires, RFPs, and compliance documentation.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "fe-file-expenses:receipt-analyzer",
    name: "Receipt Analyzer",
    emoji: "&#x1F9FE;",
    desc: "Analyzes receipt images and extracts expense data.",
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: []
  },
  {
    id: "fe-vibe-setup:vibe-profile",
    name: "Vibe Profile",
    emoji: "&#x1F464;",
    desc: "Discovers and builds a user profile including accounts, use cases, and team info.",
    tools: ["Bash","Read","Write","Grep","Glob"],
    excluded: ["Agent","Edit","WebSearch","WebFetch","Skill"]
  },
];

const ALL_TOOLS = ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch","NotebookEdit"];

// =============================================
// STATE
// =============================================
let selectedAgentType = null;
let assignedSkills = []; // [{name, desc, type:'skill'|'agent', plugin}]

// =============================================
// SHARED UTILS
// =============================================
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

// =============================================
// TAB SWITCHING
// =============================================
function switchTab(tab) {
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
  document.querySelector(`.tab-btn[onclick*="${tab}"]`).classList.add('active');
  document.getElementById(`tab-${tab}`).classList.add('active');
}

// =============================================
// OFFICE TAB (existing)
// =============================================
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

// =============================================
// AGENT LAB
// =============================================
function renderAgentTypes() {
  const list = document.getElementById('agentTypeList');
  list.innerHTML = '';
  AGENT_TYPES.forEach(at => {
    const card = document.createElement('div');
    card.className = 'agent-type-card';
    card.dataset.id = at.id;
    card.innerHTML = `
      <div class="agent-type-name">${at.emoji} ${at.name}</div>
      <div class="agent-type-desc">${at.desc}</div>
    `;
    card.onclick = () => selectAgentType(at.id);
    list.appendChild(card);
  });
}

function selectAgentType(id) {
  selectedAgentType = AGENT_TYPES.find(a => a.id === id);
  document.querySelectorAll('.agent-type-card').forEach(c => {
    c.classList.toggle('selected', c.dataset.id === id);
  });
  document.getElementById('workbenchTitle').textContent =
    `${selectedAgentType.name.toUpperCase()} AGENT`;
  renderToolsLegend();
  renderBundledSkills();
  updateCommandPreview();
}

function renderToolsLegend() {
  const legend = document.getElementById('toolsLegend');
  if (!selectedAgentType) {
    legend.innerHTML = '<span style="color:var(--text-dim);font-size:10px">Select an agent type to see its tools</span>';
    return;
  }
  legend.innerHTML = ALL_TOOLS.map(t => {
    const has = selectedAgentType.tools.includes(t);
    return `<span class="tool-chip ${has ? 'has' : 'no'}">${t}</span>`;
  }).join('');
}

// Map agent IDs to their parent plugin
function getAgentPlugin(agentId) {
  // Extract plugin name from agent ID like "fe-databricks-tools:databricks-apps-developer"
  if (agentId.includes(':')) {
    const pluginPart = agentId.split(':')[0];
    // Find matching plugin in PLUGIN_DATA
    for (const pname of Object.keys(PLUGIN_DATA)) {
      if (pname === pluginPart || pluginPart.includes(pname) || pname.includes(pluginPart)) {
        return pname;
      }
    }
  }
  return null; // Built-in agents (general-purpose, Explore, Plan)
}

function renderBundledSkills() {
  const section = document.getElementById('bundledSkillsSection');
  const bar = document.getElementById('bundledSkillsBar');

  if (!selectedAgentType) {
    section.style.display = 'none';
    return;
  }

  const pluginName = getAgentPlugin(selectedAgentType.id);

  // Built-in agents get all skills
  if (!pluginName) {
    section.style.display = 'block';
    let allCount = 0;
    for (const data of Object.values(PLUGIN_DATA)) {
      allCount += data.skills.length;
    }
    bar.innerHTML = `<span class="bundled-all-badge">&#x2728; ALL ${allCount} SKILLS (built-in agent)</span>`;
    return;
  }

  const pluginData = PLUGIN_DATA[pluginName];
  if (!pluginData || pluginData.skills.length === 0) {
    section.style.display = 'none';
    return;
  }

  section.style.display = 'block';
  const pluginLabel = pluginName.replace('fe-', '').replace(/-/g, ' ').toUpperCase();

  bar.innerHTML = pluginData.skills.map(s => {
    const name = typeof s === 'object' ? s.name : s;
    const desc = typeof s === 'object' ? s.desc : '';
    const emoji = getEmoji(name);
    return `<div class="bundled-skill-chip" title="${escapeHtml(desc)}">
      <span class="bsc-emoji">${emoji}</span>
      <span>${name}</span>
    </div>`;
  }).join('');
}

function renderPalette() {
  const grid = document.getElementById('paletteGrid');
  grid.innerHTML = '';

  // Collect all skills and agents
  const items = [];
  for (const [pluginName, data] of Object.entries(PLUGIN_DATA)) {
    data.skills.forEach(s => {
      const name = typeof s === 'object' ? s.name : s;
      const desc = typeof s === 'object' ? s.desc : '';
      items.push({ name, desc, type: 'skill', plugin: pluginName });
    });
    data.agents.forEach(a => {
      const name = typeof a === 'object' ? a.name : a;
      const desc = typeof a === 'object' ? a.desc : '';
      items.push({ name, desc, type: 'agent', plugin: pluginName });
    });
  }

  items.sort((a, b) => a.name.localeCompare(b.name));

  items.forEach(item => {
    const chip = document.createElement('div');
    const isAgent = item.type === 'agent';
    chip.className = `palette-chip${isAgent ? ' is-agent' : ''}`;
    chip.dataset.name = item.name;
    chip.dataset.desc = item.desc;
    chip.dataset.type = item.type;
    chip.dataset.plugin = item.plugin;
    chip.title = item.desc;
    chip.innerHTML = `<span class="chip-emoji">${getEmoji(item.name)}</span>${item.name}`;
    chip.onclick = () => toggleSkill(item);
    grid.appendChild(chip);
  });
}

function toggleSkill(item) {
  const idx = assignedSkills.findIndex(s => s.name === item.name && s.type === item.type);
  if (idx >= 0) {
    assignedSkills.splice(idx, 1);
  } else {
    assignedSkills.push({ ...item });
  }
  renderAssigned();
  updatePaletteHighlights();
  updateCommandPreview();
}

function removeSkill(name, type) {
  assignedSkills = assignedSkills.filter(s => !(s.name === name && s.type === type));
  renderAssigned();
  updatePaletteHighlights();
  updateCommandPreview();
}

function renderAssigned() {
  const container = document.getElementById('assignedSkills');
  const zone = document.getElementById('skillDropzone');
  container.innerHTML = '';
  zone.classList.toggle('empty', assignedSkills.length === 0);

  assignedSkills.forEach(s => {
    const chip = document.createElement('div');
    chip.className = 'assigned-chip';
    const color = s.type === 'agent' ? 'var(--yellow)' : 'var(--green)';
    chip.innerHTML = `
      ${getEmoji(s.name)}
      <span style="color:${color}">${s.name}</span>
      <span style="font-size:8px;color:var(--text-dim)">${s.type.toUpperCase()}</span>
      <span class="remove-btn" onclick="removeSkill('${s.name}','${s.type}')">&times;</span>
    `;
    container.appendChild(chip);
  });
}

function updatePaletteHighlights() {
  document.querySelectorAll('.palette-chip').forEach(chip => {
    const isAdded = assignedSkills.some(
      s => s.name === chip.dataset.name && s.type === chip.dataset.type
    );
    chip.classList.toggle('added', isAdded);
  });
}

// Palette search
document.getElementById('paletteSearch').addEventListener('input', function() {
  const q = this.value.toLowerCase().trim();
  document.querySelectorAll('.palette-chip').forEach(chip => {
    const name = chip.dataset.name.toLowerCase();
    const desc = (chip.dataset.desc || '').toLowerCase();
    chip.style.display = (!q || name.includes(q) || desc.includes(q)) ? '' : 'none';
  });
});

// Drag & drop on the dropzone
const dropzone = document.getElementById('skillDropzone');
dropzone.addEventListener('dragover', e => { e.preventDefault(); dropzone.classList.add('drag-over'); });
dropzone.addEventListener('dragleave', () => dropzone.classList.remove('drag-over'));
dropzone.addEventListener('drop', e => {
  e.preventDefault();
  dropzone.classList.remove('drag-over');
  try {
    const data = JSON.parse(e.dataTransfer.getData('text/plain'));
    if (data && data.name && !assignedSkills.some(s => s.name === data.name && s.type === data.type)) {
      assignedSkills.push(data);
      renderAssigned();
      updatePaletteHighlights();
      updateCommandPreview();
    }
  } catch(err) {}
});

// =============================================
// COMMAND GENERATION
// =============================================
function updateCommandPreview() {
  // Auto-update only if output is visible
  if (document.getElementById('commandOutput').style.display !== 'none') {
    generateCommand();
  }
}

function generateCommand() {
  const output = document.getElementById('commandOutput');
  const code = document.getElementById('commandCode');
  output.style.display = 'block';

  if (!selectedAgentType) {
    code.innerHTML = '<span class="comment">// Select an agent type from the left panel first</span>';
    return;
  }

  const taskPrompt = document.getElementById('taskPrompt').value.trim();
  const prompt = taskPrompt || 'Describe your task here...';

  // Build the skill context section
  let skillContext = '';
  if (assignedSkills.length > 0) {
    skillContext = '\\n\\nYou have access to these skills — use them as needed:\\n';
    assignedSkills.forEach(s => {
      skillContext += `- /${s.name} (${s.type}): ${s.desc}\\n`;
    });
  }

  const fullPrompt = prompt + (assignedSkills.length > 0
    ? `\n\nYou have access to these skills — use them as needed:\n${assignedSkills.map(s => `- /${s.name} (${s.type}): ${s.desc}`).join('\n')}`
    : '');

  // Format as Claude Code Agent tool call
  const escapedPrompt = escapeHtml(fullPrompt);
  const lines = [
    `<span class="comment">// Agent Tool Call for Claude Code</span>`,
    `<span class="comment">// Agent type: ${selectedAgentType.name}</span>`,
    `<span class="comment">// Tools: ${selectedAgentType.tools.join(', ')}</span>`,
    `<span class="comment">// Assigned skills: ${assignedSkills.length > 0 ? assignedSkills.map(s=>s.name).join(', ') : 'none'}</span>`,
    ``,
    `{`,
    `  <span class="kw">"subagent_type"</span>: <span class="str">"${selectedAgentType.id}"</span>,`,
    `  <span class="kw">"description"</span>: <span class="str">"${escapeHtml(taskPrompt.substring(0, 40) || 'task description')}"</span>,`,
    `  <span class="kw">"prompt"</span>: <span class="str">"${escapedPrompt.replace(/\n/g, '\\n')}"</span>`,
    `}`,
    ``,
    `<span class="comment">// Or as a natural language request to Claude Code:</span>`,
    `<span class="str">"Use the ${selectedAgentType.name} agent to ${escapeHtml(taskPrompt || '...')}${assignedSkills.length > 0 ? `. Use these skills: ${assignedSkills.map(s => '/' + s.name).join(', ')}` : ''}"</span>`,
  ];

  code.innerHTML = lines.join('\n');
}

function copyCommand() {
  if (!selectedAgentType) {
    showToast('SELECT AN AGENT FIRST');
    return;
  }

  const taskPrompt = document.getElementById('taskPrompt').value.trim() || 'Describe your task here...';

  const command = `Use the ${selectedAgentType.name} agent (${selectedAgentType.id}) to ${taskPrompt}${assignedSkills.length > 0 ? `. Use these skills: ${assignedSkills.map(s => '/' + s.name).join(', ')}` : ''}`;

  navigator.clipboard.writeText(command).then(() => {
    showToast('COPIED TO CLIPBOARD!');
  }).catch(() => {
    showToast('COPY FAILED');
  });
}

function clearLab() {
  assignedSkills = [];
  selectedAgentType = null;
  document.querySelectorAll('.agent-type-card').forEach(c => c.classList.remove('selected'));
  document.getElementById('workbenchTitle').textContent = 'CONFIGURE YOUR AGENT';
  document.getElementById('taskPrompt').value = '';
  document.getElementById('commandOutput').style.display = 'none';
  renderAssigned();
  updatePaletteHighlights();
  renderToolsLegend();
}

function showToast(msg) {
  const toast = document.getElementById('toast');
  toast.textContent = msg;
  toast.classList.add('show');
  setTimeout(() => toast.classList.remove('show'), 2000);
}

// =============================================
// MULTI-AGENT LAUNCHER (talks to vibe-server.py)
// =============================================
const runningAgents = {}; // agentId -> {evtSource, agentType, prompt, toolCount}
let serverAvailable = null;
const agentHistory = [];

async function checkServer() {
  try {
    const res = await fetch('/api/status');
    if (res.ok) { serverAvailable = true; return true; }
  } catch(e) {}
  serverAvailable = false;
  return false;
}

function showServerStatus(msg, type) {
  const el = document.getElementById('serverStatus');
  el.style.display = 'block';
  el.textContent = msg;
  const styles = {
    error: { bg: 'rgba(248,113,113,0.15)', color: 'var(--red)', border: '1px solid var(--red)' },
    ok: { bg: 'rgba(74,222,128,0.15)', color: 'var(--green)', border: '1px solid var(--green)' },
  };
  const s = styles[type] || { bg: 'rgba(251,191,36,0.15)', color: 'var(--yellow)', border: '1px solid var(--yellow)' };
  el.style.background = s.bg; el.style.color = s.color; el.style.border = s.border;
}

function updateRunningCount() {
  const count = Object.values(runningAgents).filter(a => a.status === 'running').length;
  const section = document.getElementById('runningAgentsSection');
  const countEl = document.getElementById('runningCount');
  section.style.display = Object.keys(runningAgents).length > 0 ? 'block' : 'none';
  countEl.textContent = count > 0 ? `(${count} active)` : '';
}

// Create a panel for a new agent
function createAgentPanel(agentId, agentTypeName, agentEmoji, promptPreview) {
  const container = document.getElementById('agentPanels');

  const panel = document.createElement('div');
  panel.className = 'agent-panel is-running';
  panel.id = `panel-${agentId}`;
  panel.innerHTML = `
    <div class="agent-panel-header" onclick="toggleAgentPanel('${agentId}')">
      <div class="ap-left">
        <div class="ap-avatar">${agentEmoji}</div>
        <div>
          <div class="ap-name">${agentTypeName} <span class="agent-status-badge running" id="status-${agentId}">RUNNING</span></div>
          <div class="ap-prompt-preview">${escapeHtml(promptPreview)}</div>
        </div>
      </div>
      <div class="ap-right">
        <button class="lab-btn danger" onclick="event.stopPropagation(); stopAgent('${agentId}')" id="stop-${agentId}" style="padding:3px 8px;font-size:7px">STOP</button>
        <span class="ap-toggle" id="toggle-${agentId}">&#x25BC;</span>
      </div>
    </div>
    <div class="agent-panel-body" id="body-${agentId}">
      <div class="terminal-output" id="term-${agentId}"><span class="terminal-cursor"></span></div>
    </div>
  `;

  // Insert at top
  container.insertBefore(panel, container.firstChild);
}

function toggleAgentPanel(agentId) {
  const body = document.getElementById(`body-${agentId}`);
  const toggle = document.getElementById(`toggle-${agentId}`);
  body.classList.toggle('collapsed');
  toggle.classList.toggle('collapsed');
}

async function launchAgent() {
  if (!selectedAgentType) {
    showToast('SELECT AN AGENT TYPE FIRST');
    return;
  }

  const taskPrompt = document.getElementById('taskPrompt').value.trim();
  if (!taskPrompt) {
    showToast('ENTER A TASK PROMPT');
    return;
  }

  const serverOk = await checkServer();
  if (!serverOk) {
    showServerStatus('SERVER NOT RUNNING. Start it with: python vibe-server.py', 'error');
    return;
  }

  const agentType = selectedAgentType;
  const fullPrompt = `Use the ${agentType.name} agent (subagent_type: ${agentType.id}) to: ${taskPrompt}${assignedSkills.length > 0 ? `\n\nUse these skills as needed:\n${assignedSkills.map(s => `- /${s.name} (${s.type}): ${s.desc}`).join('\n')}` : ''}`;

  try {
    const res = await fetch('/api/launch', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        prompt: fullPrompt,
        agent_type: agentType.id,
        skills: assignedSkills,
      })
    });

    const data = await res.json();
    if (data.error) {
      showToast('LAUNCH FAILED: ' + data.error);
      return;
    }

    const agentId = data.agent_id;
    const agentEmoji = agentType.emoji || '&#x1F916;';

    // Track this agent
    runningAgents[agentId] = {
      evtSource: null,
      agentType: agentType.name,
      prompt: taskPrompt,
      toolCount: 0,
      status: 'running',
    };

    // Add to history
    agentHistory.push({
      id: agentId,
      agent_type: agentType.name,
      prompt: taskPrompt.substring(0, 80),
      status: 'running',
      time: new Date().toLocaleTimeString(),
    });

    // Create panel and start streaming
    createAgentPanel(agentId, agentType.name.toUpperCase(), agentEmoji, taskPrompt);
    updateRunningCount();
    renderHistory();
    showServerStatus(`${Object.keys(runningAgents).length} agent(s) running`, 'ok');

    streamAgent(agentId);

  } catch(e) {
    showToast('LAUNCH FAILED: ' + e.message);
  }
}

// Tool icons for activity feed
const toolIcons = {
  Bash: '&#x1F4BB;', Read: '&#x1F4D6;', Write: '&#x270D;', Edit: '&#x1F4DD;',
  Glob: '&#x1F50D;', Grep: '&#x1F50E;', WebSearch: '&#x1F310;', WebFetch: '&#x1F4E5;',
  Agent: '&#x1F916;', Skill: '&#x26A1;', ToolSearch: '&#x1F527;',
  NotebookEdit: '&#x1F4D3;', TaskCreate: '&#x1F4CB;', TaskUpdate: '&#x2705;',
};

function getToolIcon(tool) {
  if (toolIcons[tool]) return toolIcons[tool];
  if (tool.startsWith('mcp__')) return '&#x1F50C;';
  return '&#x2699;';
}

function clearPendingSpinners(termOutput) {
  termOutput.querySelectorAll('.ae-spinner').forEach(s => {
    s.innerHTML = '&#x2705;';
    s.classList.remove('ae-spinner');
    s.classList.add('ae-done');
  });
}

function addActivityEvent(termOutput, html) {
  clearPendingSpinners(termOutput);
  const cursor = termOutput.querySelector('.terminal-cursor');
  if (cursor) cursor.remove();
  termOutput.insertAdjacentHTML('beforeend', html);
  termOutput.insertAdjacentHTML('beforeend', '<span class="terminal-cursor"></span>');
  termOutput.scrollTop = termOutput.scrollHeight;
}

function updateAgentStatus(agentId, status) {
  const badge = document.getElementById(`status-${agentId}`);
  const panel = document.getElementById(`panel-${agentId}`);
  if (badge) {
    badge.textContent = status.toUpperCase();
    badge.className = `agent-status-badge ${status}`;
  }
  if (panel) {
    panel.className = `agent-panel is-${status}`;
  }
  if (runningAgents[agentId]) {
    runningAgents[agentId].status = status;
  }
  const hi = agentHistory.find(h => h.id === agentId);
  if (hi) { hi.status = status; }
  updateRunningCount();
  renderHistory();
}

function streamAgent(agentId) {
  const termOutput = document.getElementById(`term-${agentId}`);
  if (!termOutput) return;

  const agent = runningAgents[agentId];
  agent.toolCount = 0;

  const evtSource = new EventSource(`/api/stream/${agentId}`);
  agent.evtSource = evtSource;

  evtSource.onmessage = function(event) {
    const msg = JSON.parse(event.data);

    if (msg.type === 'init') {
      const modelBadge = `<span style="color:var(--accent3)">${msg.model}</span>`;
      const toolCount = msg.tools ? msg.tools.length : 0;
      const mcpList = (msg.mcp_servers || []).filter(s => s.status === 'connected').map(s => s.name).join(', ');
      addActivityEvent(termOutput, `
        <div class="activity-event activity-init">
          <div class="ae-icon">&#x1F680;</div>
          <div class="ae-body">
            <div class="ae-title">Agent initialized</div>
            <div class="ae-detail">Model: ${modelBadge} | ${toolCount} tools${mcpList ? ' | MCP: ' + mcpList : ''}</div>
          </div>
        </div>`);
    }
    else if (msg.type === 'text') {
      addActivityEvent(termOutput, `
        <div class="activity-event activity-text">
          <div class="ae-icon">&#x1F4AC;</div>
          <div class="ae-body">
            <div class="ae-message">${escapeHtml(msg.data)}</div>
          </div>
        </div>`);
    }
    else if (msg.type === 'tool_call') {
      agent.toolCount++;
      const icon = getToolIcon(msg.tool);
      addActivityEvent(termOutput, `
        <div class="activity-event activity-tool">
          <div class="ae-icon">${icon}</div>
          <div class="ae-body">
            <div class="ae-title"><span class="ae-tool-name">${msg.tool}</span> <span class="ae-step">#${agent.toolCount}</span></div>
            <div class="ae-detail">${escapeHtml(msg.summary)}</div>
          </div>
          <div class="ae-spinner"></div>
        </div>`);
    }
    else if (msg.type === 'tool_result') {
      const spinners = termOutput.querySelectorAll('.ae-spinner');
      if (spinners.length > 0) {
        const last = spinners[spinners.length - 1];
        last.innerHTML = '&#x2705;';
        last.classList.remove('ae-spinner');
        last.classList.add('ae-done');
      }
    }
    else if (msg.type === 'result') {
      const cost = msg.cost ? `$${msg.cost.toFixed(4)}` : '';
      const duration = msg.duration_ms ? `${(msg.duration_ms / 1000).toFixed(1)}s` : '';
      const turns = msg.num_turns || 0;
      addActivityEvent(termOutput, `
        <div class="activity-event activity-result">
          <div class="ae-icon">&#x1F3C1;</div>
          <div class="ae-body">
            <div class="ae-title">Agent complete</div>
            <div class="ae-detail">${turns} turn${turns !== 1 ? 's' : ''} | ${duration} | ${cost}</div>
            <div class="ae-message" style="margin-top:8px">${escapeHtml(msg.data || '')}</div>
          </div>
        </div>`);
    }
    else if (msg.type === 'status') {
      updateAgentStatus(agentId, msg.status);
    }
    else if (msg.type === 'error' || msg.type === 'stderr') {
      addActivityEvent(termOutput, `
        <div class="activity-event activity-error">
          <div class="ae-icon">&#x26A0;</div>
          <div class="ae-body">
            <div class="ae-detail" style="color:var(--red)">${escapeHtml(msg.data)}</div>
          </div>
        </div>`);
    }
    else if (msg.type === 'raw') {
      addActivityEvent(termOutput, `<div class="ae-detail" style="color:var(--text-dim)">${escapeHtml(msg.data)}</div>`);
    }
    else if (msg.type === 'done') {
      evtSource.close();
      agent.evtSource = null;
      const cursor = termOutput.querySelector('.terminal-cursor');
      if (cursor) cursor.remove();
      clearPendingSpinners(termOutput);
      // Hide stop button
      const stopBtn = document.getElementById(`stop-${agentId}`);
      if (stopBtn) stopBtn.style.display = 'none';
      updateRunningCount();
    }
  };

  evtSource.onerror = function() {
    evtSource.close();
    agent.evtSource = null;
    const cursor = termOutput.querySelector('.terminal-cursor');
    if (cursor) cursor.remove();
    const stopBtn = document.getElementById(`stop-${agentId}`);
    if (stopBtn) stopBtn.style.display = 'none';
    updateRunningCount();
  };
}

async function stopAgent(agentId) {
  const agent = runningAgents[agentId];
  if (!agent) return;

  try {
    await fetch('/api/stop', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ agent_id: agentId }),
    });
  } catch(e) {}

  if (agent.evtSource) {
    agent.evtSource.close();
    agent.evtSource = null;
  }

  updateAgentStatus(agentId, 'stopped');

  const termOutput = document.getElementById(`term-${agentId}`);
  if (termOutput) {
    clearPendingSpinners(termOutput);
    const cursor = termOutput.querySelector('.terminal-cursor');
    if (cursor) cursor.remove();
    termOutput.insertAdjacentHTML('beforeend',
      '<div class="activity-event activity-error"><div class="ae-icon">&#x1F6D1;</div><div class="ae-body"><div class="ae-detail">Agent stopped by user</div></div></div>');
  }

  const stopBtn = document.getElementById(`stop-${agentId}`);
  if (stopBtn) stopBtn.style.display = 'none';
  updateRunningCount();
}

function renderHistory() {
  const panel = document.getElementById('agentHistory');
  const list = document.getElementById('historyList');
  const completed = agentHistory.filter(h => h.status !== 'running' && h.status !== 'starting');
  if (completed.length === 0) { panel.style.display = 'none'; return; }

  panel.style.display = 'block';
  list.innerHTML = '';
  [...completed].reverse().forEach(h => {
    const statusColor = {
      done: 'var(--green)', error: 'var(--red)', stopped: 'var(--text-dim)',
    }[h.status] || 'var(--text-dim)';

    list.innerHTML += `
      <div class="history-item">
        <span style="font-family:'Press Start 2P',monospace;font-size:8px;color:var(--accent3)">${h.agent_type}</span>
        <span class="hi-prompt">${escapeHtml(h.prompt)}</span>
        <span class="hi-status" style="color:${statusColor}">${h.status.toUpperCase()}</span>
        <span style="color:var(--text-dim);font-size:10px;margin-left:8px">${h.time}</span>
      </div>`;
  });
}

// =============================================
// CUSTOM AGENT CREATION & EDITING
// =============================================
const CUSTOM_AGENTS_KEY = 'vibeOfficeCustomAgents';
let modalSelectedSkills = []; // [{name, desc, type, plugin}]
let editingAgentId = null; // null = creating, string = editing

function loadCustomAgents() {
  try {
    return JSON.parse(localStorage.getItem(CUSTOM_AGENTS_KEY) || '[]');
  } catch(e) { return []; }
}

function saveCustomAgentsToStorage(agents) {
  localStorage.setItem(CUSTOM_AGENTS_KEY, JSON.stringify(agents));
  // Also save to server file for persistence
  syncCustomAgentsToServer(agents);
}

async function syncCustomAgentsToServer(agents) {
  try {
    await fetch('/api/custom-agents', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ action: 'save', agents }),
    });
  } catch(e) { /* server may not be running */ }
}

async function loadCustomAgentsFromServer() {
  try {
    const res = await fetch('/api/custom-agents', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ action: 'load' }),
    });
    if (res.ok) {
      const data = await res.json();
      return data.agents || [];
    }
  } catch(e) {}
  return null; // fallback to localStorage
}

function openCreateAgentModal() {
  editingAgentId = null;
  modalSelectedSkills = [];
  document.getElementById('customAgentName').value = '';
  document.getElementById('customAgentEmoji').value = '';
  document.getElementById('customAgentDesc').value = '';
  document.getElementById('customAgentInstructions').value = '';
  document.getElementById('modalSkillSearch').value = '';
  document.getElementById('modalSaveBtn').innerHTML = '&#x2728; CREATE AGENT';
  document.querySelector('.modal-title').textContent = 'CREATE CUSTOM AGENT';
  renderModalSkillPicker();
  document.getElementById('createAgentModal').style.display = 'flex';
}

function openEditAgentModal(customId, event) {
  if (event) event.stopPropagation();

  const agent = AGENT_TYPES.find(a => a.id === customId);
  if (!agent) return;

  editingAgentId = customId;
  modalSelectedSkills = (agent.skills || []).map(s => ({ ...s }));

  document.getElementById('customAgentName').value = agent.name;
  document.getElementById('customAgentEmoji').value = agent.emoji || '';
  document.getElementById('customAgentDesc').value = agent.desc || '';
  document.getElementById('customAgentInstructions').value = agent.instructions || '';
  document.getElementById('modalSkillSearch').value = '';
  document.getElementById('modalSaveBtn').innerHTML = '&#x1F4BE; SAVE CHANGES';
  document.querySelector('.modal-title').textContent = 'EDIT CUSTOM AGENT';

  renderModalSkillPicker();
  document.getElementById('createAgentModal').style.display = 'flex';
}

function closeCreateAgentModal() {
  document.getElementById('createAgentModal').style.display = 'none';
  editingAgentId = null;
}

function renderModalSkillPicker() {
  const picker = document.getElementById('modalSkillPicker');
  picker.innerHTML = '';

  const items = [];
  for (const [pluginName, data] of Object.entries(PLUGIN_DATA)) {
    data.skills.forEach(s => {
      const name = typeof s === 'object' ? s.name : s;
      const desc = typeof s === 'object' ? s.desc : '';
      items.push({ name, desc, type: 'skill', plugin: pluginName });
    });
    data.agents.forEach(a => {
      const name = typeof a === 'object' ? a.name : a;
      const desc = typeof a === 'object' ? a.desc : '';
      items.push({ name, desc, type: 'agent', plugin: pluginName });
    });
  }
  items.sort((a, b) => a.name.localeCompare(b.name));

  items.forEach(item => {
    const chip = document.createElement('div');
    chip.className = 'modal-skill-chip';
    chip.dataset.name = item.name;
    chip.dataset.type = item.type;
    chip.title = item.desc;
    const isSelected = modalSelectedSkills.some(s => s.name === item.name && s.type === item.type);
    if (isSelected) chip.classList.add('selected');
    chip.innerHTML = `<span class="msc-emoji">${getEmoji(item.name)}</span>${item.name}`;
    chip.onclick = () => {
      const idx = modalSelectedSkills.findIndex(s => s.name === item.name && s.type === item.type);
      if (idx >= 0) {
        modalSelectedSkills.splice(idx, 1);
        chip.classList.remove('selected');
      } else {
        modalSelectedSkills.push({ ...item });
        chip.classList.add('selected');
      }
    };
    picker.appendChild(chip);
  });
}

// Modal skill search
document.getElementById('modalSkillSearch').addEventListener('input', function() {
  const q = this.value.toLowerCase().trim();
  document.querySelectorAll('.modal-skill-chip').forEach(chip => {
    const name = chip.dataset.name.toLowerCase();
    chip.style.display = (!q || name.includes(q)) ? '' : 'none';
  });
});

function saveCustomAgent() {
  const name = document.getElementById('customAgentName').value.trim();
  const emoji = document.getElementById('customAgentEmoji').value.trim() || '&#x1F916;';
  const desc = document.getElementById('customAgentDesc').value.trim();
  const instructions = document.getElementById('customAgentInstructions').value.trim();

  if (!name) {
    showToast('ENTER AN AGENT NAME');
    return;
  }

  const customId = editingAgentId || ('custom-' + name.toLowerCase().replace(/[^a-z0-9]+/g, '-'));

  const agentData = {
    id: customId,
    name: name,
    emoji: emoji,
    desc: desc,
    instructions: instructions,
    skills: modalSelectedSkills.map(s => ({ name: s.name, desc: s.desc, type: s.type, plugin: s.plugin })),
    tools: ["Bash","Read","Write","Edit","Glob","Grep","Agent","WebSearch","WebFetch","Skill","ToolSearch"],
    excluded: [],
    isCustom: true,
  };

  const existing = loadCustomAgents();

  if (editingAgentId) {
    // Update existing
    const idx = existing.findIndex(a => a.id === editingAgentId);
    if (idx >= 0) {
      existing[idx] = agentData;
    } else {
      existing.push(agentData);
    }

    // Update in AGENT_TYPES
    const atIdx = AGENT_TYPES.findIndex(a => a.id === editingAgentId);
    if (atIdx >= 0) {
      AGENT_TYPES[atIdx] = agentData;
    }

    // Update selectedAgentType if it's the one being edited
    if (selectedAgentType && selectedAgentType.id === editingAgentId) {
      selectedAgentType = agentData;
      renderBundledSkills();
    }

    saveCustomAgentsToStorage(existing);
    renderAgentTypes();
    closeCreateAgentModal();
    showToast('AGENT UPDATED!');
  } else {
    // Create new
    if (existing.some(a => a.id === customId) || AGENT_TYPES.some(a => a.id === customId)) {
      showToast('AGENT NAME ALREADY EXISTS');
      return;
    }

    existing.push(agentData);
    saveCustomAgentsToStorage(existing);
    AGENT_TYPES.push(agentData);
    renderAgentTypes();
    closeCreateAgentModal();
    showToast('AGENT CREATED!');
    selectAgentType(customId);
  }
}

function deleteCustomAgent(customId, event) {
  if (event) event.stopPropagation();

  const agents = loadCustomAgents().filter(a => a.id !== customId);
  saveCustomAgentsToStorage(agents);

  // Remove from AGENT_TYPES
  const idx = AGENT_TYPES.findIndex(a => a.id === customId);
  if (idx >= 0) AGENT_TYPES.splice(idx, 1);

  // Deselect if currently selected
  if (selectedAgentType && selectedAgentType.id === customId) {
    selectedAgentType = null;
    document.getElementById('workbenchTitle').textContent = 'CONFIGURE YOUR AGENT';
    renderToolsLegend();
    renderBundledSkills();
  }

  renderAgentTypes();
  showToast('AGENT DELETED');
}

// Save current workbench config as a new custom agent
function saveCurrentAsAgent() {
  const taskPrompt = document.getElementById('taskPrompt').value.trim();
  const baseAgent = selectedAgentType;

  // Pre-fill the modal with current workbench state
  editingAgentId = null;
  modalSelectedSkills = assignedSkills.map(s => ({ ...s }));

  // If we have a base agent with bundled skills, include those too
  if (baseAgent && baseAgent.isCustom && baseAgent.skills) {
    baseAgent.skills.forEach(s => {
      if (!modalSelectedSkills.some(x => x.name === s.name && x.type === s.type)) {
        modalSelectedSkills.push({ ...s });
      }
    });
  }

  // Auto-generate a name suggestion from the prompt
  let suggestedName = '';
  if (taskPrompt) {
    // Take first ~40 chars of prompt as name suggestion
    suggestedName = taskPrompt.substring(0, 40).replace(/[^a-zA-Z0-9 ]/g, '').trim();
    if (taskPrompt.length > 40) suggestedName += '...';
  }

  document.getElementById('customAgentName').value = suggestedName;
  document.getElementById('customAgentEmoji').value = baseAgent ? baseAgent.emoji || '' : '';
  document.getElementById('customAgentDesc').value = baseAgent
    ? `Based on ${baseAgent.name}. ${taskPrompt ? taskPrompt.substring(0, 100) : ''}`
    : taskPrompt ? taskPrompt.substring(0, 100) : '';
  document.getElementById('customAgentInstructions').value = taskPrompt;
  document.getElementById('modalSkillSearch').value = '';
  document.getElementById('modalSaveBtn').innerHTML = '&#x2728; CREATE AGENT';
  document.querySelector('.modal-title').textContent = 'SAVE AS CUSTOM AGENT';

  renderModalSkillPicker();
  document.getElementById('createAgentModal').style.display = 'flex';
}

// Override launchAgent to inject custom agent instructions
const _originalLaunchAgent = launchAgent;
launchAgent = async function() {
  if (!selectedAgentType) {
    showToast('SELECT AN AGENT TYPE FIRST');
    return;
  }

  const taskPrompt = document.getElementById('taskPrompt').value.trim();
  if (!taskPrompt) {
    showToast('ENTER A TASK PROMPT');
    return;
  }

  const serverOk = await checkServer();
  if (!serverOk) {
    showServerStatus('SERVER NOT RUNNING. Start it with: python vibe-server.py', 'error');
    return;
  }

  const agentType = selectedAgentType;

  // Build prompt with custom instructions if present
  let fullPrompt = '';
  if (agentType.isCustom && agentType.instructions) {
    fullPrompt += agentType.instructions + '\n\n';
  }
  fullPrompt += taskPrompt;

  // Add assigned skills: merge custom agent's built-in skills + any extras from the palette
  const allSkills = [];
  if (agentType.isCustom && agentType.skills && agentType.skills.length > 0) {
    agentType.skills.forEach(s => {
      if (!allSkills.some(x => x.name === s.name)) allSkills.push(s);
    });
  }
  assignedSkills.forEach(s => {
    if (!allSkills.some(x => x.name === s.name)) allSkills.push(s);
  });

  if (allSkills.length > 0) {
    fullPrompt += '\n\nYou have access to these skills — use them as needed:\n';
    fullPrompt += allSkills.map(s => `- /${s.name} (${s.type}): ${s.desc}`).join('\n');
  }

  try {
    const res = await fetch('/api/launch', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        prompt: fullPrompt,
        agent_type: agentType.id,
        skills: allSkills,
      })
    });

    const data = await res.json();
    if (data.error) {
      showToast('LAUNCH FAILED: ' + data.error);
      return;
    }

    const agentId = data.agent_id;
    const agentEmoji = agentType.emoji || '&#x1F916;';

    runningAgents[agentId] = {
      evtSource: null,
      agentType: agentType.name,
      prompt: taskPrompt,
      toolCount: 0,
      status: 'running',
    };

    agentHistory.push({
      id: agentId,
      agent_type: agentType.name,
      prompt: taskPrompt.substring(0, 80),
      status: 'running',
      time: new Date().toLocaleTimeString(),
    });

    createAgentPanel(agentId, agentType.name.toUpperCase(), agentEmoji, taskPrompt);
    updateRunningCount();
    renderHistory();
    showServerStatus(`${Object.keys(runningAgents).length} agent(s) running`, 'ok');

    streamAgent(agentId);

  } catch(e) {
    showToast('LAUNCH FAILED: ' + e.message);
  }
};

// Load custom agents on startup — try server file first, fallback to localStorage
async function initCustomAgents() {
  let custom = [];

  // Try loading from server file
  const serverAgents = await loadCustomAgentsFromServer();
  if (serverAgents && serverAgents.length > 0) {
    custom = serverAgents;
    // Sync to localStorage as backup
    localStorage.setItem(CUSTOM_AGENTS_KEY, JSON.stringify(custom));
  } else {
    custom = loadCustomAgents();
    // If we have local agents but server doesn't, sync to server
    if (custom.length > 0) {
      syncCustomAgentsToServer(custom);
    }
  }

  custom.forEach(a => {
    a.isCustom = true; // ensure flag is set
    if (!AGENT_TYPES.some(at => at.id === a.id)) {
      AGENT_TYPES.push(a);
    }
  });
}

// Override renderAgentTypes to show custom badge and delete button
const _origRenderAgentTypes = renderAgentTypes;
renderAgentTypes = function() {
  const list = document.getElementById('agentTypeList');
  list.innerHTML = '';
  AGENT_TYPES.forEach(at => {
    const card = document.createElement('div');
    card.className = 'agent-type-card';
    card.dataset.id = at.id;
    if (selectedAgentType && selectedAgentType.id === at.id) card.classList.add('selected');

    let nameHtml = `${at.emoji} ${at.name}`;
    if (at.isCustom) {
      nameHtml += `<span class="custom-badge">CUSTOM</span>`;
    }

    let actionBtns = '';
    if (at.isCustom) {
      actionBtns = `<div style="float:right;display:flex;gap:4px">
        <span class="custom-action-btn edit-btn" onclick="openEditAgentModal('${at.id}', event)" title="Edit this agent">&#x270F;&#xFE0F;</span>
        <span class="custom-action-btn delete-btn" onclick="deleteCustomAgent('${at.id}', event)" title="Delete this agent">&#x1F5D1;</span>
      </div>`;
    }

    let skillCount = '';
    if (at.isCustom && at.skills && at.skills.length > 0) {
      skillCount = `<div style="margin-top:6px;font-size:8px;font-family:'Press Start 2P',monospace;color:var(--accent1)">${at.skills.length} SKILLS ASSIGNED</div>`;
    }

    card.innerHTML = `
      ${actionBtns}
      <div class="agent-type-name">${nameHtml}</div>
      <div class="agent-type-desc">${at.desc}</div>
      ${skillCount}
    `;
    card.onclick = () => selectAgentType(at.id);
    list.appendChild(card);
  });
};

// Override renderBundledSkills to handle custom agents
const _origRenderBundledSkills = renderBundledSkills;
renderBundledSkills = function() {
  const section = document.getElementById('bundledSkillsSection');
  const bar = document.getElementById('bundledSkillsBar');

  if (!selectedAgentType) {
    section.style.display = 'none';
    return;
  }

  // Custom agents show their assigned skills
  if (selectedAgentType.isCustom) {
    const skills = selectedAgentType.skills || [];
    if (skills.length === 0) {
      section.style.display = 'block';
      bar.innerHTML = '<span style="color:var(--text-dim);font-size:10px;font-family:Inter">No skills assigned — add skills when editing or use the skill palette below</span>';
      return;
    }
    section.style.display = 'block';
    bar.innerHTML = skills.map(s => {
      const emoji = getEmoji(s.name);
      return `<div class="bundled-skill-chip" title="${escapeHtml(s.desc || '')}">
        <span class="bsc-emoji">${emoji}</span>
        <span>${s.name}</span>
      </div>`;
    }).join('');
    return;
  }

  // Fall back to original logic for built-in agents
  _origRenderBundledSkills();
};

// =============================================
// WORKFLOWS
// =============================================
const WF_STORAGE_KEY = 'vibeOfficeWorkflows';
let wfSteps = []; // [{name, prompt, skills, agentId}]
let savedWorkflows = [];
let selectedWorkflowIdx = -1;
let activeWorkflowId = null;
let activeWorkflowEvtSource = null;

// Track running workflow status per workflow index
// workflowRunStatus[idx] = {status:'running'|'done'|'error', wfId, steps, wfTermHtml}
const workflowRunStatus = {};
// Unsaved drafts: wfDrafts[idx] = {name, steps} — auto-saved on switch
const wfDrafts = {};
// Draft for "new" (unsaved) workflow
let newWfDraft = null;

// Collect all available skills for the step skill picker
function getAllSkillItems() {
  const items = [];
  for (const [pluginName, data] of Object.entries(PLUGIN_DATA)) {
    data.skills.forEach(s => {
      const name = typeof s === 'object' ? s.name : s;
      const desc = typeof s === 'object' ? s.desc : '';
      items.push({ name, desc, type: 'skill', plugin: pluginName });
    });
  }
  items.sort((a, b) => a.name.localeCompare(b.name));
  return items;
}

function stashCurrentDraft() {
  syncStepPrompts();
  const draft = {
    name: document.getElementById('wfName').value,
    steps: wfSteps.map(s => ({ name: s.name, prompt: s.prompt, skills: [...s.skills], agentId: s.agentId })),
  };
  if (selectedWorkflowIdx >= 0) {
    wfDrafts[selectedWorkflowIdx] = draft;
  } else {
    newWfDraft = draft;
  }
}

function newWorkflow() {
  stashCurrentDraft();
  selectedWorkflowIdx = -1;

  // Restore new draft if exists
  if (newWfDraft && newWfDraft.steps.length > 0) {
    document.getElementById('wfName').value = newWfDraft.name || '';
    wfSteps = newWfDraft.steps.map(s => ({ ...s, skills: [...(s.skills || [])] }));
  } else {
    document.getElementById('wfName').value = '';
    wfSteps = [];
    addPipelineStep();
    addPipelineStep();
  }
  document.getElementById('wfExecutionStatus').style.display = 'none';
  renderPipeline();
  renderWfList();
}

function addPipelineStep() {
  wfSteps.push({
    name: `Step ${wfSteps.length + 1}`,
    prompt: '',
    skills: [],
    agentId: null,
  });
  renderPipeline();
}

function removePipelineStep(idx) {
  if (wfSteps.length <= 1) {
    showToast('NEED AT LEAST 1 STEP');
    return;
  }
  wfSteps.splice(idx, 1);
  // Renumber
  wfSteps.forEach((s, i) => {
    if (s.name.match(/^Step \d+$/)) s.name = `Step ${i + 1}`;
  });
  renderPipeline();
}

// Get all agent options (built-in + custom)
function getAgentOptions() {
  return AGENT_TYPES.map(at => ({
    id: at.id,
    name: at.name,
    emoji: at.emoji,
    isCustom: at.isCustom || false,
    skills: at.skills || [],
    instructions: at.instructions || '',
  }));
}

function renderPipeline() {
  const builder = document.getElementById('pipelineBuilder');
  builder.innerHTML = '';

  const allSkills = getAllSkillItems();
  const agentOptions = getAgentOptions();

  wfSteps.forEach((step, idx) => {
    // Wire connector (except before first step)
    if (idx > 0) {
      const wireLabel = idx === 1 ? 'OUTPUT &#x2192; CONTEXT' : 'PASS THROUGH';
      builder.innerHTML += `
        <div class="pipeline-wire" id="connector-${idx}">
          <div class="wire-line"></div>
          <div class="wire-arrow"></div>
          <div class="wire-label">${wireLabel}</div>
        </div>`;
    }

    // Agent selector options
    const agentSelectHtml = agentOptions.map(a =>
      `<option value="${a.id}" ${step.agentId === a.id ? 'selected' : ''}>${a.name}${a.isCustom ? ' (custom)' : ''}</option>`
    ).join('');

    // Skills HTML
    const skillsHtml = allSkills.map(s => {
      const isActive = step.skills.some(ss => ss.name === s.name);
      return `<div class="node-skill-toggle ${isActive ? 'active' : ''}"
        onclick="toggleStepSkill(${idx}, '${s.name.replace(/'/g, "\\'")}', this)"
        title="${escapeHtml(s.desc)}">${getEmoji(s.name)} ${s.name}</div>`;
    }).join('');

    // Agent badge
    const selectedAgent = step.agentId ? agentOptions.find(a => a.id === step.agentId) : null;
    const agentBadge = selectedAgent
      ? `<span style="font-size:14px">${selectedAgent.emoji}</span>`
      : `<span style="font-size:14px">&#x1F916;</span>`;

    builder.innerHTML += `
      <div class="pipeline-node" id="step-${idx}">
        ${idx > 0 ? '<div class="node-port input-port" id="port-in-' + idx + '"></div>' : ''}
        <div class="node-topbar">
          <div class="node-topbar-left">
            <div class="node-number">${idx + 1}</div>
            <input type="text" class="node-name-input" value="${escapeHtml(step.name)}"
              onchange="wfSteps[${idx}].name = this.value" placeholder="Step name...">
          </div>
          <div class="node-topbar-right">
            ${agentBadge}
            <div class="step-remove" onclick="removePipelineStep(${idx})" title="Remove step">&times;</div>
          </div>
        </div>
        <div class="node-body">
          <div class="node-agent-row">
            <span class="node-agent-label">AGENT</span>
            <select class="node-agent-select" onchange="setStepAgent(${idx}, this.value)">
              <option value="">-- No agent (general) --</option>
              ${agentSelectHtml}
            </select>
          </div>
          <textarea class="node-prompt" placeholder="What should this step do?&#10;${idx > 0 ? '(receives output from Step ' + idx + ' as context)' : '(first step — starts the pipeline)'}"
            onchange="wfSteps[${idx}].prompt = this.value">${escapeHtml(step.prompt)}</textarea>
          <div class="node-extras">
            <details>
              <summary>SKILLS &amp; TOOLS (${step.skills.length} selected)</summary>
              <div class="node-extras-content">${skillsHtml}</div>
            </details>
          </div>
          <div class="step-status-indicator" id="step-status-${idx}"></div>
          <div class="step-terminal" id="step-term-${idx}"></div>
        </div>
        ${idx < wfSteps.length - 1 ? '<div class="node-port output-port" id="port-out-' + idx + '"></div>' : '<div class="node-port output-port" id="port-out-' + idx + '" style="border-style:dashed"></div>'}
      </div>`;
  });
}

function setStepAgent(stepIdx, agentId) {
  wfSteps[stepIdx].agentId = agentId || null;
  // If agent has bundled skills, auto-add them
  if (agentId) {
    const agent = AGENT_TYPES.find(a => a.id === agentId);
    if (agent && agent.isCustom && agent.skills) {
      agent.skills.forEach(s => {
        if (!wfSteps[stepIdx].skills.some(ss => ss.name === s.name)) {
          wfSteps[stepIdx].skills.push({ ...s });
        }
      });
    }
  }
  renderPipeline();
}

function toggleStepSkill(stepIdx, skillName, el) {
  const step = wfSteps[stepIdx];
  const allSkills = getAllSkillItems();
  const skill = allSkills.find(s => s.name === skillName);
  if (!skill) return;

  const idx = step.skills.findIndex(s => s.name === skillName);
  if (idx >= 0) {
    step.skills.splice(idx, 1);
    el.classList.remove('active');
  } else {
    step.skills.push({ ...skill });
    el.classList.add('active');
  }

  // Update summary count
  const details = el.closest('details');
  if (details) {
    const summary = details.querySelector('summary');
    summary.textContent = `SKILLS (${step.skills.length} selected)`;
  }
}

function saveWorkflow() {
  const name = document.getElementById('wfName').value.trim();
  if (!name) {
    showToast('ENTER A WORKFLOW NAME');
    return;
  }

  // Sync prompts from textareas
  syncStepPrompts();

  const wfData = {
    name,
    steps: wfSteps.map(s => ({ name: s.name, prompt: s.prompt, skills: s.skills, agentId: s.agentId || null })),
    createdAt: new Date().toISOString(),
  };

  if (selectedWorkflowIdx >= 0) {
    savedWorkflows[selectedWorkflowIdx] = wfData;
  } else {
    savedWorkflows.push(wfData);
    selectedWorkflowIdx = savedWorkflows.length - 1;
  }

  persistWorkflows();
  renderWfList();
  showToast('WORKFLOW SAVED!');
}

function syncStepPrompts() {
  document.querySelectorAll('.node-prompt').forEach((ta, idx) => {
    if (wfSteps[idx]) wfSteps[idx].prompt = ta.value;
  });
  document.querySelectorAll('.node-name-input').forEach((inp, idx) => {
    if (wfSteps[idx]) wfSteps[idx].name = inp.value;
  });
  document.querySelectorAll('.node-agent-select').forEach((sel, idx) => {
    if (wfSteps[idx]) wfSteps[idx].agentId = sel.value || null;
  });
}

function loadWorkflow(idx) {
  const wf = savedWorkflows[idx];
  if (!wf) return;

  // Stash current before switching
  stashCurrentDraft();

  selectedWorkflowIdx = idx;

  // Use draft if available, otherwise use saved
  const source = wfDrafts[idx] || wf;
  document.getElementById('wfName').value = source.name;
  wfSteps = source.steps.map(s => ({
    name: s.name,
    prompt: s.prompt,
    skills: (s.skills || []).map(sk => ({ ...sk })),
    agentId: s.agentId || null,
  }));

  // Show/hide execution log for this workflow
  const runInfo = workflowRunStatus[idx];
  const wfExec = document.getElementById('wfExecutionStatus');
  const wfTerm = document.getElementById('wfTerminal');
  if (runInfo && runInfo.wfTermHtml) {
    wfExec.style.display = 'block';
    wfTerm.innerHTML = runInfo.wfTermHtml;
  } else {
    wfExec.style.display = 'none';
  }

  renderPipeline();

  // Restore step terminal HTML and statuses if this workflow ran
  if (runInfo && runInfo.stepStates) {
    runInfo.stepStates.forEach((ss, i) => {
      const stepEl = document.getElementById(`step-${i}`);
      const statusEl = document.getElementById(`step-status-${i}`);
      const termEl = document.getElementById(`step-term-${i}`);
      if (ss.nodeClass && stepEl) stepEl.className = ss.nodeClass;
      if (ss.statusHtml && statusEl) {
        statusEl.className = ss.statusClass || 'step-status-indicator visible';
        statusEl.innerHTML = ss.statusHtml;
      }
      if (ss.termHtml && termEl) {
        termEl.className = 'step-terminal visible';
        termEl.innerHTML = ss.termHtml;
      }
      // Ports + wires
      const conn = document.getElementById(`connector-${i}`);
      if (conn && ss.wireClass) conn.className = ss.wireClass;
      const portIn = document.getElementById(`port-in-${i}`);
      const portOut = document.getElementById(`port-out-${i}`);
      if (portIn && ss.portInClass) portIn.className = ss.portInClass;
      if (portOut && ss.portOutClass) portOut.className = ss.portOutClass;
    });
  }

  renderWfList();
}

function deleteWorkflow(idx, event) {
  if (event) event.stopPropagation();
  savedWorkflows.splice(idx, 1);
  if (selectedWorkflowIdx === idx) {
    selectedWorkflowIdx = -1;
    newWorkflow();
  } else if (selectedWorkflowIdx > idx) {
    selectedWorkflowIdx--;
  }
  persistWorkflows();
  renderWfList();
  showToast('WORKFLOW DELETED');
}

function renderWfList() {
  const list = document.getElementById('wfList');
  list.innerHTML = '';

  if (savedWorkflows.length === 0) {
    list.innerHTML = '<div style="color:var(--text-dim);font-size:11px;padding:12px;text-align:center;font-family:Inter">No saved workflows yet. Click + NEW to create one.</div>';
    return;
  }

  savedWorkflows.forEach((wf, idx) => {
    const card = document.createElement('div');
    card.className = `wf-card${idx === selectedWorkflowIdx ? ' selected' : ''}`;

    // Status icon
    const runInfo = workflowRunStatus[idx];
    let statusIcon = '&#x1F504;'; // default: loop icon
    let statusBorder = '';
    if (runInfo) {
      if (runInfo.status === 'running') {
        statusIcon = '<span style="display:inline-block;width:12px;height:12px;border:2px solid var(--cyan);border-top-color:transparent;border-radius:50%;animation:spin 0.8s linear infinite;vertical-align:middle"></span>';
        statusBorder = 'border-left: 3px solid var(--cyan);';
      } else if (runInfo.status === 'done') {
        statusIcon = '&#x2705;';
        statusBorder = 'border-left: 3px solid var(--green);';
      } else if (runInfo.status === 'error') {
        statusIcon = '&#x274C;';
        statusBorder = 'border-left: 3px solid var(--red);';
      } else if (runInfo.status === 'stopped') {
        statusIcon = '&#x1F6D1;';
        statusBorder = 'border-left: 3px solid var(--text-dim);';
      }
    }

    card.style.cssText = statusBorder;

    card.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:start">
        <div class="wf-card-name">${statusIcon} ${escapeHtml(wf.name)}</div>
        <div style="display:flex;gap:4px">
          <span class="custom-action-btn edit-btn" onclick="loadWorkflow(${idx}); event.stopPropagation()" title="Edit" style="width:24px;height:24px;font-size:13px">&#x270F;&#xFE0F;</span>
          <span class="custom-action-btn delete-btn" onclick="deleteWorkflow(${idx}, event)" title="Delete" style="width:24px;height:24px;font-size:13px">&#x1F5D1;</span>
        </div>
      </div>
      <div class="wf-card-steps">${wf.steps.length} STEPS${runInfo ? ' — ' + runInfo.status.toUpperCase() : ''}</div>
      <div class="wf-card-desc">${wf.steps.map(s => s.name).join(' → ')}</div>
    `;
    card.onclick = () => loadWorkflow(idx);
    list.appendChild(card);
  });
}

function persistWorkflows() {
  localStorage.setItem(WF_STORAGE_KEY, JSON.stringify(savedWorkflows));
  // Also save to server
  fetch('/api/workflows', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ action: 'save', workflows: savedWorkflows }),
  }).catch(() => {});
}

async function loadWorkflowsFromStorage() {
  // Try server first
  try {
    const res = await fetch('/api/workflows', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ action: 'load' }),
    });
    if (res.ok) {
      const data = await res.json();
      if (data.workflows && data.workflows.length > 0) {
        savedWorkflows = data.workflows;
        localStorage.setItem(WF_STORAGE_KEY, JSON.stringify(savedWorkflows));
        return;
      }
    }
  } catch(e) {}

  // Fallback to localStorage
  try {
    savedWorkflows = JSON.parse(localStorage.getItem(WF_STORAGE_KEY) || '[]');
  } catch(e) { savedWorkflows = []; }
}

async function runWorkflow() {
  syncStepPrompts();

  const validSteps = wfSteps.filter(s => s.prompt.trim());
  if (validSteps.length === 0) {
    showToast('ADD PROMPTS TO YOUR STEPS');
    return;
  }

  const serverOk = await checkServer();
  if (!serverOk) {
    showToast('SERVER NOT RUNNING');
    return;
  }

  // Reset step statuses
  wfSteps.forEach((s, i) => {
    const statusEl = document.getElementById(`step-status-${i}`);
    const termEl = document.getElementById(`step-term-${i}`);
    const stepEl = document.getElementById(`step-${i}`);
    if (statusEl) { statusEl.className = 'step-status-indicator'; statusEl.innerHTML = ''; }
    if (termEl) { termEl.className = 'step-terminal'; termEl.innerHTML = ''; }
    if (stepEl) { stepEl.className = 'pipeline-step'; }
    const conn = document.getElementById(`connector-${i}`);
    if (conn) conn.className = 'pipeline-connector';
  });

  // Show execution section
  document.getElementById('wfExecutionStatus').style.display = 'block';
  const wfTerm = document.getElementById('wfTerminal');
  wfTerm.innerHTML = '<span class="terminal-cursor"></span>';

  const wfName = document.getElementById('wfName').value.trim() || 'Workflow';

  // Build steps with agent instructions injected
  const stepsPayload = wfSteps.map(s => {
    let prompt = '';
    if (s.agentId) {
      const agent = AGENT_TYPES.find(a => a.id === s.agentId);
      if (agent && agent.isCustom && agent.instructions) {
        prompt += agent.instructions + '\n\n';
      }
    }
    prompt += s.prompt;

    // Merge agent skills + step skills
    const allSkills = [...(s.skills || [])];
    if (s.agentId) {
      const agent = AGENT_TYPES.find(a => a.id === s.agentId);
      if (agent && agent.isCustom && agent.skills) {
        agent.skills.forEach(sk => {
          if (!allSkills.some(x => x.name === sk.name)) allSkills.push(sk);
        });
      }
    }
    return { name: s.name, prompt, skills: allSkills };
  });

  try {
    const res = await fetch('/api/workflow/launch', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        name: wfName,
        steps: stepsPayload,
      }),
    });

    const data = await res.json();
    if (data.error) {
      showToast('LAUNCH FAILED: ' + data.error);
      return;
    }

    activeWorkflowId = data.workflow_id;
    document.getElementById('runWfBtn').innerHTML = '&#x23F8; RUNNING...';
    document.getElementById('runWfBtn').disabled = true;

    // Track this run
    if (selectedWorkflowIdx >= 0) {
      workflowRunStatus[selectedWorkflowIdx] = {
        status: 'running',
        wfId: data.workflow_id,
        wfTermHtml: '',
        stepStates: wfSteps.map(() => ({})),
        ownerIdx: selectedWorkflowIdx,
      };
      renderWfList();
    }

    streamWorkflow(data.workflow_id, selectedWorkflowIdx);

  } catch(e) {
    showToast('LAUNCH FAILED: ' + e.message);
  }
}

function streamWorkflow(wfId, ownerIdx) {
  const wfTerm = document.getElementById('wfTerminal');
  const evtSource = new EventSource(`/api/workflow/stream/${wfId}`);
  activeWorkflowEvtSource = evtSource;

  // Helper: save step DOM state to workflowRunStatus for restoration when switching back
  function snapshotStepState(stepIdx) {
    if (ownerIdx < 0 || !workflowRunStatus[ownerIdx]) return;
    const ss = workflowRunStatus[ownerIdx].stepStates;
    if (!ss[stepIdx]) ss[stepIdx] = {};
    const stepEl = document.getElementById(`step-${stepIdx}`);
    const statusEl = document.getElementById(`step-status-${stepIdx}`);
    const termEl = document.getElementById(`step-term-${stepIdx}`);
    const conn = document.getElementById(`connector-${stepIdx}`);
    const portIn = document.getElementById(`port-in-${stepIdx}`);
    const portOut = document.getElementById(`port-out-${stepIdx}`);
    if (stepEl) ss[stepIdx].nodeClass = stepEl.className;
    if (statusEl) { ss[stepIdx].statusClass = statusEl.className; ss[stepIdx].statusHtml = statusEl.innerHTML; }
    if (termEl) ss[stepIdx].termHtml = termEl.innerHTML;
    if (conn) ss[stepIdx].wireClass = conn.className;
    if (portIn) ss[stepIdx].portInClass = portIn.className;
    if (portOut) ss[stepIdx].portOutClass = portOut.className;
  }

  function snapshotWfTerm() {
    if (ownerIdx >= 0 && workflowRunStatus[ownerIdx]) {
      workflowRunStatus[ownerIdx].wfTermHtml = wfTerm.innerHTML;
    }
  }

  evtSource.onmessage = function(event) {
    const msg = JSON.parse(event.data);
    // Check if we're still viewing this workflow
    const isViewing = selectedWorkflowIdx === ownerIdx;

    if (msg.type === 'step_start') {
      const stepIdx = msg.step;
      if (isViewing) {
        const stepEl = document.getElementById(`step-${stepIdx}`);
        const statusEl = document.getElementById(`step-status-${stepIdx}`);
        const termEl = document.getElementById(`step-term-${stepIdx}`);

        if (stepEl) stepEl.classList.add('active-step');
        if (statusEl) {
          statusEl.className = 'step-status-indicator visible running';
          statusEl.innerHTML = '<div class="ae-spinner" style="width:14px;height:14px"></div> Running...';
        }
        if (termEl) {
          termEl.className = 'step-terminal visible';
          termEl.innerHTML = '<span class="terminal-cursor"></span>';
        }

        if (stepIdx > 0) {
          const conn = document.getElementById(`connector-${stepIdx}`);
          if (conn) conn.classList.add('active');
        }
        const portIn = document.getElementById(`port-in-${stepIdx}`);
        const portOut = document.getElementById(`port-out-${stepIdx}`);
        if (portIn) portIn.classList.add('active');
        if (portOut) portOut.classList.add('active');

        addWfLogEvent(wfTerm, `
          <div class="activity-event activity-init">
            <div class="ae-icon">&#x25B6;</div>
            <div class="ae-body">
              <div class="ae-title">Step ${stepIdx + 1}: ${escapeHtml(msg.name)}</div>
              <div class="ae-detail">Starting step ${stepIdx + 1} of ${msg.total}</div>
            </div>
          </div>`);
        snapshotStepState(stepIdx);
        snapshotWfTerm();
      }
    }

    else if (msg.type === 'step_complete') {
      const stepIdx = msg.step;
      if (isViewing) {
        const stepEl = document.getElementById(`step-${stepIdx}`);
        const statusEl = document.getElementById(`step-status-${stepIdx}`);
        if (stepEl) { stepEl.classList.remove('active-step'); stepEl.classList.add('done-step'); }
        if (statusEl) {
          statusEl.className = 'step-status-indicator visible complete';
          statusEl.innerHTML = '&#x2705; Complete';
        }
        if (stepIdx > 0) {
          const conn = document.getElementById(`connector-${stepIdx}`);
          if (conn) { conn.classList.remove('active'); conn.classList.add('done'); }
        }
        const portIn = document.getElementById(`port-in-${stepIdx}`);
        const portOut = document.getElementById(`port-out-${stepIdx}`);
        if (portIn) { portIn.classList.remove('active'); portIn.classList.add('done'); }
        if (portOut) { portOut.classList.remove('active'); portOut.classList.add('done'); }

        addWfLogEvent(wfTerm, `
          <div class="activity-event activity-result">
            <div class="ae-icon">&#x2705;</div>
            <div class="ae-body">
              <div class="ae-title">Step ${stepIdx + 1} complete: ${escapeHtml(msg.name)}</div>
              ${msg.result_preview ? `<div class="ae-detail" style="margin-top:4px">${escapeHtml(msg.result_preview.substring(0, 200))}${msg.result_preview.length > 200 ? '...' : ''}</div>` : ''}
            </div>
          </div>`);
        snapshotStepState(stepIdx);
        snapshotWfTerm();
      } else {
        // Not viewing but update cached state
        if (workflowRunStatus[ownerIdx] && workflowRunStatus[ownerIdx].stepStates[msg.step]) {
          workflowRunStatus[ownerIdx].stepStates[msg.step].nodeClass = 'pipeline-node done-step';
          workflowRunStatus[ownerIdx].stepStates[msg.step].statusClass = 'step-status-indicator visible complete';
          workflowRunStatus[ownerIdx].stepStates[msg.step].statusHtml = '&#x2705; Complete';
        }
      }
    }

    else if (msg.type === 'step_error') {
      const stepIdx = msg.step;
      if (isViewing) {
        const stepEl = document.getElementById(`step-${stepIdx}`);
        const statusEl = document.getElementById(`step-status-${stepIdx}`);
        if (stepEl) { stepEl.classList.remove('active-step'); stepEl.classList.add('error-step'); }
        if (statusEl) {
          statusEl.className = 'step-status-indicator visible error';
          statusEl.innerHTML = '&#x274C; Error: ' + escapeHtml(msg.error);
        }
        addWfLogEvent(wfTerm, `
          <div class="activity-event activity-error">
            <div class="ae-icon">&#x274C;</div>
            <div class="ae-body">
              <div class="ae-title">Step ${stepIdx + 1} failed: ${escapeHtml(msg.name)}</div>
              <div class="ae-detail">${escapeHtml(msg.error)}</div>
            </div>
          </div>`);
        snapshotStepState(stepIdx);
        snapshotWfTerm();
      }
    }

    // Per-step streaming events
    else if (msg.step !== undefined && isViewing) {
      const termEl = document.getElementById(`step-term-${msg.step}`);
      if (termEl) {
        if (msg.type === 'init') {
          addStepEvent(termEl, `
            <div class="activity-event activity-init" style="padding:4px 8px;margin-bottom:4px">
              <div class="ae-icon" style="font-size:12px">&#x1F680;</div>
              <div class="ae-body"><div class="ae-detail">Initialized | ${msg.tools ? msg.tools.length : 0} tools</div></div>
            </div>`);
        }
        else if (msg.type === 'tool_call') {
          addStepEvent(termEl, `
            <div class="activity-event activity-tool" style="padding:4px 8px;margin-bottom:4px">
              <div class="ae-icon" style="font-size:12px">${getToolIcon(msg.tool)}</div>
              <div class="ae-body"><div class="ae-detail"><span style="color:var(--cyan)">${msg.tool}</span> ${escapeHtml(msg.summary)}</div></div>
              <div class="ae-spinner" style="width:12px;height:12px"></div>
            </div>`);
        }
        else if (msg.type === 'text') {
          addStepEvent(termEl, `
            <div class="activity-event activity-text" style="padding:4px 8px;margin-bottom:4px">
              <div class="ae-icon" style="font-size:12px">&#x1F4AC;</div>
              <div class="ae-body"><div class="ae-detail">${escapeHtml(msg.data).substring(0, 300)}</div></div>
            </div>`);
        }
        else if (msg.type === 'result') {
          addStepEvent(termEl, `
            <div class="activity-event activity-result" style="padding:4px 8px;margin-bottom:4px">
              <div class="ae-icon" style="font-size:12px">&#x1F3C1;</div>
              <div class="ae-body"><div class="ae-detail">${msg.num_turns} turns | ${msg.cost ? '$' + msg.cost.toFixed(4) : ''}</div></div>
            </div>`);
        }
        snapshotStepState(msg.step);
      }
    }

    else if (msg.type === 'workflow_status') {
      if (ownerIdx >= 0 && workflowRunStatus[ownerIdx]) {
        workflowRunStatus[ownerIdx].status = msg.status;
        renderWfList();
      }
      if (isViewing && (msg.status === 'done' || msg.status === 'error' || msg.status === 'stopped')) {
        addWfLogEvent(wfTerm, `
          <div class="activity-event ${msg.status === 'done' ? 'activity-result' : 'activity-error'}">
            <div class="ae-icon">${msg.status === 'done' ? '&#x1F3C6;' : '&#x26A0;'}</div>
            <div class="ae-body">
              <div class="ae-title">Workflow ${msg.status.toUpperCase()}</div>
            </div>
          </div>`);
        snapshotWfTerm();
      }
    }

    else if (msg.type === 'done') {
      evtSource.close();
      activeWorkflowEvtSource = null;
      activeWorkflowId = null;
      if (isViewing) {
        document.getElementById('runWfBtn').innerHTML = '&#x25B6; RUN';
        document.getElementById('runWfBtn').disabled = false;
        const cursor = wfTerm.querySelector('.terminal-cursor');
        if (cursor) cursor.remove();
        snapshotWfTerm();
      }
      if (ownerIdx >= 0 && workflowRunStatus[ownerIdx]) {
        if (workflowRunStatus[ownerIdx].status === 'running') {
          workflowRunStatus[ownerIdx].status = 'done';
        }
        renderWfList();
      }
    }
  };

  evtSource.onerror = function() {
    evtSource.close();
    activeWorkflowEvtSource = null;
    if (selectedWorkflowIdx === ownerIdx) {
      document.getElementById('runWfBtn').innerHTML = '&#x25B6; RUN';
      document.getElementById('runWfBtn').disabled = false;
    }
    if (ownerIdx >= 0 && workflowRunStatus[ownerIdx]) {
      workflowRunStatus[ownerIdx].status = 'error';
      renderWfList();
    }
  };
}

function addWfLogEvent(termEl, html) {
  clearPendingSpinners(termEl);
  const cursor = termEl.querySelector('.terminal-cursor');
  if (cursor) cursor.remove();
  termEl.insertAdjacentHTML('beforeend', html);
  termEl.insertAdjacentHTML('beforeend', '<span class="terminal-cursor"></span>');
  termEl.scrollTop = termEl.scrollHeight;
}

function addStepEvent(termEl, html) {
  // Clear spinners from previous tool calls in this step
  termEl.querySelectorAll('.ae-spinner').forEach(s => {
    s.innerHTML = '&#x2705;';
    s.classList.remove('ae-spinner');
    s.classList.add('ae-done');
    s.style.width = 'auto'; s.style.height = 'auto';
    s.style.border = 'none'; s.style.animation = 'none';
  });
  termEl.insertAdjacentHTML('beforeend', html);
  termEl.scrollTop = termEl.scrollHeight;
}

function clearWorkflow() {
  if (activeWorkflowEvtSource) {
    activeWorkflowEvtSource.close();
    activeWorkflowEvtSource = null;
  }
  if (activeWorkflowId) {
    fetch('/api/workflow/stop', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ workflow_id: activeWorkflowId }),
    }).catch(() => {});
    activeWorkflowId = null;
  }
  document.getElementById('runWfBtn').innerHTML = '&#x25B6; RUN WORKFLOW';
  document.getElementById('runWfBtn').disabled = false;
  document.getElementById('wfExecutionStatus').style.display = 'none';
  newWorkflow();
}

// Check server on load
checkServer();

// =============================================
// INIT
// =============================================
(async function() {
  await initCustomAgents();
  await loadWorkflowsFromStorage();
  render();
  renderAgentTypes();
  renderPalette();
  renderToolsLegend();
  renderWfList();
  // Initialize with 2 empty steps
  if (wfSteps.length === 0) {
    addPipelineStep();
    addPipelineStep();
  }
})();
</script>
</body>
</html>
JSEOF

echo ""
echo "Vibe Office generated at: $OUTPUT"
echo "Open it with: open $OUTPUT"
