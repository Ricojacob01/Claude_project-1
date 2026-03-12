# Vibe Office
<img width="2312" height="1118" alt="image" src="https://github.com/user-attachments/assets/f6c0b299-df42-4bd2-bf36-bcf11110fdda" />

A pixel-art dashboard that visualizes all your installed Claude Code plugins, skills, and agents as an interactive "office" UI.

![Vibe Office](https://img.shields.io/badge/style-pixel%20art-blueviolet) ![Claude Code](https://img.shields.io/badge/Claude%20Code-plugins-green)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/Ricojacob01/Claude_project-1.git
cd Claude_project-1

# Generate your personalized Vibe Office
chmod +x vibe-office.sh
./vibe-office.sh

# Open it
open vibe-office.html
```

## How It Works

The `vibe-office.sh` script scans your `~/.claude/plugins/cache/` directory to discover all installed plugins, skills, and agents. It generates a self-contained HTML file with:

- **Pixel-art themed UI** using Press Start 2P font
- **Department sections** for each plugin (collapsible)
- **Skill & Agent cards** with contextual emoji icons and float animations
- **Search bar** to filter across all skills and agents
- **Category filters** to focus on a specific plugin
- **Stats bar** showing total departments, skills, and agents

## Requirements

- Claude Code with plugins installed (`~/.claude/plugins/cache/`)
- Bash shell
- A web browser

## Customization

You can pass a custom output path:

```bash
./vibe-office.sh ~/Desktop/my-office.html
```

The script auto-detects:
- Plugin names and versions
- Skills (from `skills/` directories)
- Agents (from `agents/` directories, `.md` or `.json` files)
- Assigns contextual emoji icons based on skill/agent names

## Plugin Structure Expected

```
~/.claude/plugins/cache/
  └── <namespace>/           # e.g., fe-vibe
      ├── fe-databricks-tools/
      │   └── 1.0.6/
      │       ├── skills/
      │       │   ├── databricks-apps/
      │       │   └── ...
      │       └── agents/
      │           └── databricks-apps-developer.md
      ├── fe-google-tools/
      │   └── 1.1.10/
      │       ├── skills/
      │       └── agents/
      └── ...
```
