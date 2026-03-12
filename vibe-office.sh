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

  /* Terminal output */
  .terminal-output {
    background: #0a0a14;
    border: 1px solid #334;
    border-radius: 8px;
    padding: 14px;
    font-family: 'Menlo', 'Monaco', 'Courier New', monospace;
    font-size: 12px;
    color: var(--green);
    white-space: pre-wrap;
    word-break: break-word;
    max-height: 500px;
    overflow-y: auto;
    line-height: 1.6;
    min-height: 100px;
  }
  .terminal-output .t-line { margin-bottom: 2px; }
  .terminal-output .t-system { color: var(--accent3); }
  .terminal-output .t-error { color: var(--red); }
  .terminal-output .t-dim { color: var(--text-dim); }

  .terminal-cursor {
    display: inline-block;
    width: 8px; height: 14px;
    background: var(--green);
    animation: blink 1s step-end infinite;
    vertical-align: text-bottom;
  }
  @keyframes blink { 50% { opacity: 0; } }

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

  /* Responsive */
  @media (max-width: 900px) {
    .agent-lab { flex-direction: column; }
    .lab-sidebar { width: 100%; min-width: 0; }
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
  <button class="tab-btn" onclick="switchTab('lab')">AGENT LAB<span class="tab-badge">NEW</span></button>
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
      <div class="lab-section-title">SELECT AGENT TYPE</div>
      <div id="agentTypeList"></div>
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

      <!-- Live Agent Terminal -->
      <div class="command-output" id="terminalPanel" style="display:none">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
          <div class="prompt-label" style="margin:0">
            <span id="terminalTitle">AGENT OUTPUT</span>
            <span id="terminalStatus" class="agent-status-badge"></span>
          </div>
          <button class="lab-btn danger" onclick="stopAgent()" id="stopBtn" style="padding:4px 10px;font-size:8px;display:none">STOP</button>
        </div>
        <div class="terminal-output" id="terminalOutput"></div>
      </div>

      <!-- Agent History -->
      <div id="agentHistory" style="display:none">
        <div class="prompt-label" style="margin-bottom:8px">AGENT HISTORY</div>
        <div id="historyList"></div>
      </div>
    </div>
  </div>
</div>

<div class="footer">
  VIBE OFFICE v2.0 // Auto-generated from ~/.claude/plugins
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
  // Update sidebar selection
  document.querySelectorAll('.agent-type-card').forEach(c => {
    c.classList.toggle('selected', c.dataset.id === id);
  });
  // Update workbench title
  document.getElementById('workbenchTitle').textContent =
    `${selectedAgentType.name.toUpperCase()} AGENT`;
  // Update tools legend
  renderToolsLegend();
  // Update command
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
// AGENT LAUNCHER (talks to vibe-server.py)
// =============================================
let currentAgentId = null;
let currentEventSource = null;
let serverAvailable = null;
const agentHistory = [];

async function checkServer() {
  try {
    const res = await fetch('/api/status');
    if (res.ok) {
      serverAvailable = true;
      return true;
    }
  } catch(e) {}
  serverAvailable = false;
  return false;
}

function showServerStatus(msg, type) {
  const el = document.getElementById('serverStatus');
  el.style.display = 'block';
  el.textContent = msg;
  if (type === 'error') {
    el.style.background = 'rgba(248,113,113,0.15)';
    el.style.color = 'var(--red)';
    el.style.border = '1px solid var(--red)';
  } else if (type === 'ok') {
    el.style.background = 'rgba(74,222,128,0.15)';
    el.style.color = 'var(--green)';
    el.style.border = '1px solid var(--green)';
  } else {
    el.style.background = 'rgba(251,191,36,0.15)';
    el.style.color = 'var(--yellow)';
    el.style.border = '1px solid var(--yellow)';
  }
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

  // Check server
  const serverOk = await checkServer();
  if (!serverOk) {
    showServerStatus('SERVER NOT RUNNING. Start it with: python vibe-server.py', 'error');
    return;
  }

  // Build prompt
  const fullPrompt = `Use the ${selectedAgentType.name} agent (subagent_type: ${selectedAgentType.id}) to: ${taskPrompt}${assignedSkills.length > 0 ? `\n\nUse these skills as needed:\n${assignedSkills.map(s => `- /${s.name} (${s.type}): ${s.desc}`).join('\n')}` : ''}`;

  // Show terminal
  const termPanel = document.getElementById('terminalPanel');
  const termOutput = document.getElementById('terminalOutput');
  const termTitle = document.getElementById('terminalTitle');
  const termStatus = document.getElementById('terminalStatus');
  const stopBtn = document.getElementById('stopBtn');
  const launchBtn = document.getElementById('launchBtn');

  termPanel.style.display = 'block';
  termOutput.innerHTML = '<span class="t-system">Launching agent...</span>\n<span class="terminal-cursor"></span>';
  termTitle.textContent = `${selectedAgentType.name.toUpperCase()} AGENT`;
  termStatus.textContent = 'STARTING';
  termStatus.className = 'agent-status-badge starting';
  stopBtn.style.display = 'inline-block';
  launchBtn.disabled = true;

  try {
    const res = await fetch('/api/launch', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        prompt: fullPrompt,
        agent_type: selectedAgentType.id,
        skills: assignedSkills,
      })
    });

    const data = await res.json();
    if (data.error) {
      termOutput.innerHTML = `<span class="t-error">Error: ${escapeHtml(data.error)}</span>`;
      termStatus.textContent = 'ERROR';
      termStatus.className = 'agent-status-badge error';
      launchBtn.disabled = false;
      return;
    }

    currentAgentId = data.agent_id;
    showServerStatus(`Agent ${currentAgentId} launched`, 'ok');

    // Add to history
    agentHistory.push({
      id: currentAgentId,
      agent_type: selectedAgentType.name,
      prompt: taskPrompt.substring(0, 80),
      status: 'running',
      time: new Date().toLocaleTimeString(),
    });
    renderHistory();

    // Stream output via SSE
    streamAgent(currentAgentId);

  } catch(e) {
    termOutput.innerHTML = `<span class="t-error">Launch failed: ${escapeHtml(e.message)}</span>`;
    termStatus.textContent = 'ERROR';
    termStatus.className = 'agent-status-badge error';
    launchBtn.disabled = false;
  }
}

function streamAgent(agentId) {
  const termOutput = document.getElementById('terminalOutput');
  const termStatus = document.getElementById('terminalStatus');
  const stopBtn = document.getElementById('stopBtn');
  const launchBtn = document.getElementById('launchBtn');

  termOutput.innerHTML = '';
  let outputBuffer = '';

  const evtSource = new EventSource(`/api/stream/${agentId}`);
  currentEventSource = evtSource;

  evtSource.onmessage = function(event) {
    const msg = JSON.parse(event.data);

    if (msg.type === 'output') {
      outputBuffer += msg.data;
      termOutput.innerHTML = escapeHtml(outputBuffer) + '<span class="terminal-cursor"></span>';
      termOutput.scrollTop = termOutput.scrollHeight;
    }
    else if (msg.type === 'status') {
      termStatus.textContent = msg.status.toUpperCase();
      termStatus.className = `agent-status-badge ${msg.status}`;

      if (msg.status === 'running') {
        termOutput.innerHTML += '<span class="t-system">Agent is running...</span>\n';
      }

      // Update history
      const hi = agentHistory.find(h => h.id === agentId);
      if (hi) { hi.status = msg.status; renderHistory(); }
    }
    else if (msg.type === 'error') {
      termOutput.innerHTML += `\n<span class="t-error">Error: ${escapeHtml(msg.data)}</span>`;
    }
    else if (msg.type === 'done') {
      evtSource.close();
      currentEventSource = null;
      currentAgentId = null;
      stopBtn.style.display = 'none';
      launchBtn.disabled = false;
      // Remove cursor
      const cursor = termOutput.querySelector('.terminal-cursor');
      if (cursor) cursor.remove();
      termOutput.innerHTML += '\n<span class="t-dim">--- agent finished ---</span>';
      termOutput.scrollTop = termOutput.scrollHeight;
    }
  };

  evtSource.onerror = function() {
    evtSource.close();
    currentEventSource = null;
    stopBtn.style.display = 'none';
    launchBtn.disabled = false;
    const cursor = termOutput.querySelector('.terminal-cursor');
    if (cursor) cursor.remove();
    termOutput.innerHTML += '\n<span class="t-dim">--- connection closed ---</span>';
  };
}

async function stopAgent() {
  if (!currentAgentId) return;

  try {
    await fetch('/api/stop', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ agent_id: currentAgentId }),
    });
  } catch(e) {}

  if (currentEventSource) {
    currentEventSource.close();
    currentEventSource = null;
  }

  document.getElementById('terminalStatus').textContent = 'STOPPED';
  document.getElementById('terminalStatus').className = 'agent-status-badge stopped';
  document.getElementById('stopBtn').style.display = 'none';
  document.getElementById('launchBtn').disabled = false;

  const termOutput = document.getElementById('terminalOutput');
  const cursor = termOutput.querySelector('.terminal-cursor');
  if (cursor) cursor.remove();
  termOutput.innerHTML += '\n<span class="t-dim">--- agent stopped by user ---</span>';

  const hi = agentHistory.find(h => h.id === currentAgentId);
  if (hi) { hi.status = 'stopped'; renderHistory(); }
  currentAgentId = null;
}

function renderHistory() {
  const panel = document.getElementById('agentHistory');
  const list = document.getElementById('historyList');
  if (agentHistory.length === 0) { panel.style.display = 'none'; return; }

  panel.style.display = 'block';
  list.innerHTML = '';
  [...agentHistory].reverse().forEach(h => {
    const statusColor = {
      running: 'var(--cyan)', done: 'var(--green)',
      error: 'var(--red)', stopped: 'var(--text-dim)', starting: 'var(--yellow)',
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

// Check server on load
checkServer().then(ok => {
  if (!ok) {
    // Only show warning if on Agent Lab tab — don't clutter Office view
  }
});

// =============================================
// INIT
// =============================================
render();
renderAgentTypes();
renderPalette();
renderToolsLegend();
</script>
</body>
</html>
JSEOF

echo ""
echo "Vibe Office generated at: $OUTPUT"
echo "Open it with: open $OUTPUT"
