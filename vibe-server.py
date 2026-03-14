#!/usr/bin/env python3
"""
Vibe Office Server - Local agent launcher for Claude Code
Run: python vibe-server.py
Then open: http://localhost:5555
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import queue
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

PORT = int(os.environ.get("VIBE_PORT", 5555))
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Find claude CLI
CLAUDE_BIN = None
for candidate in [
    os.path.expanduser("~/.local/bin/claude"),
    shutil.which("claude") or "",
    shutil.which("claude-code") or "",
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
]:
    if candidate and os.path.isfile(candidate):
        CLAUDE_BIN = candidate
        break

if not CLAUDE_BIN:
    print("ERROR: Could not find 'claude' CLI. Install it first.")
    print("Try: npm install -g @anthropic-ai/claude-code")
    sys.exit(1)

print(f"Using Claude CLI: {CLAUDE_BIN}")

# Active agent processes
active_agents = {}
agent_counter = 0
agent_lock = threading.Lock()

# Active workflows
active_workflows = {}
workflow_counter = 0
workflow_lock = threading.Lock()


def parse_stream_event(line, q, step_idx=None, step_name=None):
    """Parse a stream-json line from claude CLI and emit UI-friendly events.
    step_idx can be an integer (legacy) or a string step_id (DAG).
    """
    try:
        evt = json.loads(line)
    except json.JSONDecodeError:
        msg = {"type": "raw", "data": line}
        if step_idx is not None:
            msg["step"] = step_idx
            msg["step_id"] = step_idx
            if step_name:
                msg["step_name"] = step_name
        q.put(msg)
        return

    evt_type = evt.get("type", "")

    # Permission / approval requests
    if evt_type == "system" and evt.get("subtype") in ("permission_request", "tool_use_permission"):
        tool_name = evt.get("tool", {}).get("name", "") if isinstance(evt.get("tool"), dict) else evt.get("tool", "")
        msg = {
            "type": "approval_needed",
            "tool": tool_name,
            "message": evt.get("message", "Permission required"),
        }
        if step_idx is not None:
            msg["step"] = step_idx
            msg["step_id"] = step_idx
            if step_name:
                msg["step_name"] = step_name
        q.put(msg)
        return

    if evt_type == "system" and evt.get("subtype") == "init":
        msg = {
            "type": "init",
            "model": evt.get("model", ""),
            "tools": evt.get("tools", []),
            "session_id": evt.get("session_id", ""),
            "mcp_servers": evt.get("mcp_servers", []),
        }
        if step_idx is not None:
            msg["step"] = step_idx
            msg["step_id"] = step_idx
            if step_name:
                msg["step_name"] = step_name
        q.put(msg)

    elif evt_type == "assistant":
        content_blocks = evt.get("message", {}).get("content", [])

        for block in content_blocks:
            if block.get("type") == "text":
                text = block.get("text", "")
                if text.strip():
                    msg = {"type": "text", "data": text}
                    if step_idx is not None:
                        msg["step"] = step_idx
                        msg["step_id"] = step_idx
                        if step_name:
                            msg["step_name"] = step_name
                    q.put(msg)

            elif block.get("type") == "tool_use":
                tool_name = block.get("name", "unknown")
                tool_input = block.get("input", {})
                tool_id = block.get("id", "")
                summary = summarize_tool_call(tool_name, tool_input)
                msg = {
                    "type": "tool_call",
                    "tool": tool_name,
                    "summary": summary,
                    "input": truncate_obj(tool_input, 300),
                    "tool_id": tool_id,
                }
                if step_idx is not None:
                    msg["step"] = step_idx
                    msg["step_id"] = step_idx
                    if step_name:
                        msg["step_name"] = step_name
                q.put(msg)

            elif block.get("type") == "tool_result":
                tool_id = block.get("tool_use_id", "")
                content = block.get("content", "")
                if isinstance(content, list):
                    content = " ".join(
                        c.get("text", "") for c in content if c.get("type") == "text"
                    )
                msg = {
                    "type": "tool_result",
                    "tool_id": tool_id,
                    "result": str(content)[:500],
                }
                if step_idx is not None:
                    msg["step"] = step_idx
                    msg["step_id"] = step_idx
                    if step_name:
                        msg["step_name"] = step_name
                q.put(msg)

    elif evt_type == "result":
        msg = {
            "type": "result",
            "data": evt.get("result", ""),
            "cost": evt.get("total_cost_usd", 0),
            "duration_ms": evt.get("duration_ms", 0),
            "num_turns": evt.get("num_turns", 0),
        }
        if step_idx is not None:
            msg["step"] = step_idx
            msg["step_id"] = step_idx
            if step_name:
                msg["step_name"] = step_name
        q.put(msg)


def summarize_tool_call(tool_name, tool_input):
    """Create a short human-readable summary of what a tool call does."""
    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        return f"Running: {cmd[:120]}"
    elif tool_name == "Read":
        path = tool_input.get("file_path", "")
        return f"Reading: {path.split('/')[-1] if '/' in path else path}"
    elif tool_name == "Write":
        path = tool_input.get("file_path", "")
        return f"Writing: {path.split('/')[-1] if '/' in path else path}"
    elif tool_name == "Edit":
        path = tool_input.get("file_path", "")
        return f"Editing: {path.split('/')[-1] if '/' in path else path}"
    elif tool_name == "Glob":
        pattern = tool_input.get("pattern", "")
        return f"Searching files: {pattern}"
    elif tool_name == "Grep":
        pattern = tool_input.get("pattern", "")
        return f"Searching code: {pattern[:80]}"
    elif tool_name == "WebSearch":
        query = tool_input.get("query", "")
        return f"Web search: {query[:80]}"
    elif tool_name == "WebFetch":
        url = tool_input.get("url", "")
        return f"Fetching: {url[:80]}"
    elif tool_name == "Agent":
        desc = tool_input.get("description", "")
        sub = tool_input.get("subagent_type", "")
        return f"Launching subagent ({sub}): {desc}"
    elif tool_name == "Skill":
        skill = tool_input.get("skill", "")
        return f"Using skill: /{skill}"
    elif tool_name == "ToolSearch":
        query = tool_input.get("query", "")
        return f"Searching tools: {query}"
    elif tool_name.startswith("mcp__"):
        parts = tool_name.split("__")
        service = parts[1] if len(parts) > 1 else "mcp"
        action = parts[2] if len(parts) > 2 else tool_name
        return f"MCP {service}: {action}"
    else:
        return f"{tool_name}"


def truncate_obj(obj, max_len):
    """Truncate an object's string representation."""
    s = json.dumps(obj, ensure_ascii=False)
    if len(s) > max_len:
        return s[:max_len] + "..."
    return s


def run_agent(agent_id, prompt, resume_session=None):
    """Run claude CLI with stream-json output and parse events."""
    agent = active_agents[agent_id]
    q = agent["output_queue"]

    try:
        agent["status"] = "running"
        q.put({"type": "status", "status": "running"})

        result_text = run_claude_cli(prompt, q, resume_session=resume_session, agent_id=agent_id)
        agent["result"] = result_text
        agent["status"] = "done"
        q.put({"type": "status", "status": "done", "exit_code": 0})

    except Exception as e:
        agent["status"] = "error"
        q.put({"type": "error", "data": str(e)})

    q.put({"type": "done"})


def run_claude_cli(prompt, q, step_idx=None, step_name=None, resume_session=None, agent_id=None):
    """Run claude CLI and stream events to queue. Returns result text."""
    clean_env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    clean_env["NO_COLOR"] = "1"

    cmd = [CLAUDE_BIN, "-p", prompt, "--output-format", "stream-json", "--verbose"]
    if resume_session:
        cmd.extend(["--resume", resume_session])

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=clean_env,
    )

    # Store process reference for agent followups
    if agent_id and agent_id in active_agents:
        active_agents[agent_id]["process"] = proc

    result_text = ""
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        parse_stream_event(line, q, step_idx, step_name=step_name)
        # Capture result text and session_id
        try:
            evt = json.loads(line)
            if evt.get("type") == "result":
                result_text = evt.get("result", "")
            # Capture session_id from init event for follow-ups
            if evt.get("type") == "system" and evt.get("subtype") == "init":
                sid = evt.get("session_id", "")
                if sid and agent_id and agent_id in active_agents:
                    active_agents[agent_id]["session_id"] = sid
        except json.JSONDecodeError:
            pass

    proc.wait()
    exit_code = proc.returncode

    stderr_out = proc.stderr.read()
    if stderr_out and stderr_out.strip():
        msg = {"type": "stderr", "data": stderr_out.strip()[:500]}
        if step_idx is not None:
            msg["step"] = step_idx
            msg["step_id"] = step_idx
        q.put(msg)

    if exit_code != 0:
        raise RuntimeError(f"Claude CLI exited with code {exit_code}")

    return result_text


def run_workflow(workflow_id):
    """Run a DAG-based workflow with concurrent execution."""
    wf = active_workflows[workflow_id]
    q = wf["output_queue"]
    steps = wf["steps"]
    is_dag = wf.get("dag", False)

    # If not DAG format, fall back to legacy linear execution
    if not is_dag:
        run_workflow_linear(workflow_id)
        return

    total = len(steps)
    try:
        wf["status"] = "running"
        q.put({"type": "workflow_status", "status": "running", "total_steps": total})

        # Build lookup maps
        step_map = {s["id"]: s for s in steps}
        # Track results and errors per step
        step_results = {}  # id -> result_text
        step_errors = {}   # id -> error_msg
        step_done = set()
        step_lock = threading.Lock()

        def get_children(parent_id):
            return [s for s in steps if parent_id in s.get("parentIds", [])]

        def get_parents(step):
            return [step_map[pid] for pid in step.get("parentIds", []) if pid in step_map]

        def can_run(step):
            """Check if a step's trigger conditions are met."""
            parent_ids = step.get("parentIds", [])
            trigger = step.get("trigger", "on_complete")

            if not parent_ids:
                return True  # Root step

            if trigger == "on_failure":
                # Runs only if ANY parent failed
                return any(pid in step_errors for pid in parent_ids)

            if trigger == "on_all_parents":
                # Runs only when ALL parents are done (success or skipped)
                return all(pid in step_done for pid in parent_ids)

            # on_complete: runs when ANY parent completes successfully
            return any(pid in step_results for pid in parent_ids)

        def should_skip(step):
            """Check if a step should be skipped."""
            parent_ids = step.get("parentIds", [])
            trigger = step.get("trigger", "on_complete")

            if not parent_ids:
                return False

            if trigger == "on_failure":
                # Skip if no parent has failed
                return not any(pid in step_errors for pid in parent_ids)

            if trigger == "on_all_parents":
                # Skip if any parent errored (and no on_failure handler)
                all_done = all(pid in step_done for pid in parent_ids)
                if not all_done:
                    return False
                # Check if all parents that are done succeeded
                return False  # Don't skip, just run

            # on_complete: skip if all parents errored
            return all(pid in step_errors and pid not in step_results for pid in parent_ids)

        def build_context(step):
            """Build prompt context from parent outputs."""
            parent_ids = step.get("parentIds", [])
            trigger = step.get("trigger", "on_complete")
            context_parts = []

            if trigger == "on_failure":
                for pid in parent_ids:
                    if pid in step_errors:
                        context_parts.append(f"PARENT STEP FAILED WITH ERROR:\n{step_errors[pid]}")
            else:
                for pid in parent_ids:
                    if pid in step_results and step_results[pid]:
                        parent_name = step_map[pid].get("name", pid)
                        context_parts.append(f"CONTEXT FROM {parent_name}:\n{step_results[pid]}")

            return "\n\n".join(context_parts)

        def run_step(step):
            """Execute a single DAG step."""
            step_id = step["id"]
            step_name = step.get("name", step_id)
            step_prompt = step.get("prompt", "")
            step_skills = step.get("skills", [])

            # Check if should skip
            if should_skip(step):
                q.put({
                    "type": "step_complete",
                    "step_id": step_id,
                    "name": step_name,
                    "result_preview": "(skipped)",
                    "skipped": True,
                })
                with step_lock:
                    step_done.add(step_id)
                return

            # Build full prompt
            context = build_context(step)
            full_prompt = ""
            if context:
                full_prompt += context + "\n\n"
            full_prompt += step_prompt

            if step_skills:
                skill_list = "\n".join(
                    f"- /{s['name']} ({s.get('type', 'skill')}): {s.get('desc', '')}"
                    for s in step_skills
                )
                full_prompt += f"\n\nYou have access to these skills — use them as needed:\n{skill_list}"

            # Signal step start
            q.put({
                "type": "step_start",
                "step_id": step_id,
                "name": step_name,
                "total": total,
            })

            try:
                result_text = run_claude_cli(full_prompt, q, step_idx=step_id, step_name=step_name)
                with step_lock:
                    step_results[step_id] = result_text
                    step_done.add(step_id)

                q.put({
                    "type": "step_complete",
                    "step_id": step_id,
                    "name": step_name,
                    "result_preview": result_text[:2000] if result_text else "",
                })

            except Exception as e:
                error_msg = str(e)
                with step_lock:
                    step_errors[step_id] = error_msg
                    step_done.add(step_id)

                q.put({
                    "type": "step_error",
                    "step_id": step_id,
                    "name": step_name,
                    "error": error_msg,
                })

        # BFS-style level execution
        # Compute levels
        levels = {}
        visited = set()
        bfs_queue = []
        for s in steps:
            if not s.get("parentIds"):
                levels[s["id"]] = 0
                bfs_queue.append(s["id"])
                visited.add(s["id"])

        while bfs_queue:
            curr_id = bfs_queue.pop(0)
            children = get_children(curr_id)
            for child in children:
                new_level = levels[curr_id] + 1
                levels[child["id"]] = max(levels.get(child["id"], 0), new_level)
                if child["id"] not in visited:
                    visited.add(child["id"])
                    bfs_queue.append(child["id"])

        # Handle orphans
        for s in steps:
            if s["id"] not in levels:
                levels[s["id"]] = 0

        max_level = max(levels.values()) if levels else 0

        for lvl in range(max_level + 1):
            level_steps = [s for s in steps if levels.get(s["id"]) == lvl]

            # Filter to only runnable steps
            runnable = [s for s in level_steps if can_run(s)]
            skippable = [s for s in level_steps if s not in runnable]

            # Mark skipped steps
            for s in skippable:
                sid = s["id"]
                q.put({
                    "type": "step_complete",
                    "step_id": sid,
                    "name": s.get("name", sid),
                    "result_preview": "(skipped — trigger condition not met)",
                    "skipped": True,
                })
                with step_lock:
                    step_done.add(sid)

            if not runnable:
                continue

            # Run steps at this level in parallel
            if len(runnable) == 1:
                run_step(runnable[0])
            else:
                threads = []
                for s in runnable:
                    t = threading.Thread(target=run_step, args=(s,))
                    t.start()
                    threads.append(t)
                for t in threads:
                    t.join()

            # Check if workflow should stop (all paths errored, no failure handlers)
            # Only stop if there are no more runnable steps in future levels
            if wf.get("status") == "stopped":
                q.put({"type": "done"})
                return

        # Collect final output from leaf nodes (steps with no children)
        leaf_outputs = []
        for s in steps:
            if not get_children(s["id"]) and s["id"] in step_results:
                leaf_outputs.append(step_results[s["id"]])

        final_output = "\n\n".join(leaf_outputs) if leaf_outputs else ""

        wf["status"] = "done"
        q.put({"type": "workflow_status", "status": "done", "final_output": final_output[:3000]})

    except Exception as e:
        wf["status"] = "error"
        q.put({"type": "workflow_error", "data": str(e)})

    q.put({"type": "done"})


def run_workflow_linear(workflow_id):
    """Legacy linear workflow execution (for old-format workflows)."""
    wf = active_workflows[workflow_id]
    q = wf["output_queue"]
    steps = wf["steps"]
    total = len(steps)

    try:
        wf["status"] = "running"
        q.put({"type": "workflow_status", "status": "running", "total_steps": total})

        previous_output = ""
        previous_error = None

        for i, step in enumerate(steps):
            wf["current_step"] = i
            step_name = step.get("name", f"Step {i+1}")
            step_prompt = step.get("prompt", "")
            step_skills = step.get("skills", [])
            trigger = step.get("trigger", "on_complete")

            if trigger == "on_failure" and previous_error is None:
                q.put({
                    "type": "step_complete", "step": i, "name": step_name,
                    "result_preview": "(skipped — previous step succeeded)", "skipped": True,
                })
                continue
            elif trigger == "on_failure" and previous_error:
                step_prompt = f"THE PREVIOUS STEP FAILED WITH ERROR:\n{previous_error}\n\n{step_prompt}"
            elif trigger != "on_failure" and previous_error:
                wf["status"] = "error"
                q.put({"type": "workflow_status", "status": "error"})
                q.put({"type": "done"})
                return

            full_prompt = ""
            if previous_output:
                full_prompt += f"CONTEXT FROM PREVIOUS STEP:\n{previous_output}\n\n"
            full_prompt += step_prompt

            if step_skills:
                skill_list = "\n".join(
                    f"- /{s['name']} ({s.get('type', 'skill')}): {s.get('desc', '')}"
                    for s in step_skills
                )
                full_prompt += f"\n\nYou have access to these skills — use them as needed:\n{skill_list}"

            q.put({"type": "step_start", "step": i, "name": step_name, "total": total})

            try:
                result_text = run_claude_cli(full_prompt, q, step_idx=i)
                previous_output = result_text
                q.put({
                    "type": "step_complete", "step": i, "name": step_name,
                    "result_preview": result_text[:2000] if result_text else "",
                })
            except Exception as e:
                error_msg = str(e)
                q.put({"type": "step_error", "step": i, "name": step_name, "error": error_msg})
                next_step = steps[i + 1] if i + 1 < total else None
                if next_step and next_step.get("trigger") == "on_failure":
                    previous_error = error_msg
                    continue
                wf["status"] = "error"
                q.put({"type": "workflow_status", "status": "error"})
                q.put({"type": "done"})
                return

            previous_error = None

        wf["status"] = "done"
        q.put({"type": "workflow_status", "status": "done", "final_output": previous_output[:3000] if previous_output else ""})

    except Exception as e:
        wf["status"] = "error"
        q.put({"type": "workflow_error", "data": str(e)})

    q.put({"type": "done"})


class VibeHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/" or parsed.path == "/index.html":
            self.serve_html()
        elif parsed.path == "/api/status":
            self.send_json({
                "status": "ok",
                "claude_bin": CLAUDE_BIN,
                "active_agents": len(active_agents),
                "active_workflows": len(active_workflows),
            })
        elif parsed.path == "/api/agents":
            agents_summary = {}
            with agent_lock:
                for aid, a in active_agents.items():
                    agents_summary[aid] = {
                        "status": a["status"],
                        "prompt": a["prompt"][:100],
                    }
            self.send_json(agents_summary)
        elif parsed.path.startswith("/api/stream/"):
            agent_id = parsed.path.split("/")[-1]
            self.stream_agent(agent_id)
        elif parsed.path.startswith("/api/workflow/stream/"):
            wf_id = parsed.path.split("/")[-1]
            self.stream_workflow(wf_id)
        else:
            super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/launch":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            prompt = data.get("prompt", "")
            skills = data.get("skills", [])

            if not prompt:
                self.send_json({"error": "No prompt provided"}, 400)
                return

            full_prompt = prompt
            if skills:
                skill_list = "\n".join(f"- /{s['name']} ({s['type']}): {s.get('desc', '')}" for s in skills)
                full_prompt += f"\n\nYou have access to these skills — use them as needed:\n{skill_list}"

            global agent_counter
            with agent_lock:
                agent_counter += 1
                agent_id = f"agent-{agent_counter}"
                active_agents[agent_id] = {
                    "process": None,
                    "output_queue": queue.Queue(),
                    "status": "starting",
                    "prompt": full_prompt,
                    "result": "",
                }

            thread = threading.Thread(target=run_agent, args=(agent_id, full_prompt), daemon=True)
            thread.start()

            self.send_json({"agent_id": agent_id, "status": "starting"})

        elif parsed.path == "/api/followup":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            agent_id = data.get("agent_id", "")
            message = data.get("message", "")

            if not agent_id or not message:
                self.send_json({"error": "agent_id and message required"}, 400)
                return

            agent = active_agents.get(agent_id)
            if not agent:
                self.send_json({"error": "Agent not found"}, 404)
                return

            session_id = agent.get("session_id", "")
            if not session_id:
                self.send_json({"error": "No session_id available for this agent"}, 400)
                return

            # Reset agent state for follow-up
            agent["output_queue"] = queue.Queue()
            agent["status"] = "running"
            agent["result"] = ""

            thread = threading.Thread(
                target=run_agent,
                args=(agent_id, message),
                kwargs={"resume_session": session_id},
                daemon=True,
            )
            thread.start()

            self.send_json({"agent_id": agent_id, "status": "running", "session_id": session_id})

        elif parsed.path == "/api/workflow/launch":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            steps = data.get("steps", [])
            name = data.get("name", "Workflow")

            if not steps:
                self.send_json({"error": "No steps provided"}, 400)
                return

            is_dag = data.get("dag", False)

            global workflow_counter
            with workflow_lock:
                workflow_counter += 1
                wf_id = f"wf-{workflow_counter}"
                active_workflows[wf_id] = {
                    "output_queue": queue.Queue(),
                    "status": "starting",
                    "name": name,
                    "steps": steps,
                    "current_step": -1,
                    "dag": is_dag,
                }

            thread = threading.Thread(target=run_workflow, args=(wf_id,), daemon=True)
            thread.start()

            self.send_json({"workflow_id": wf_id, "status": "starting"})

        elif parsed.path == "/api/workflow/stop":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            wf_id = data.get("workflow_id", "")

            with workflow_lock:
                wf = active_workflows.get(wf_id)
                if wf:
                    wf["status"] = "stopped"
                    wf["output_queue"].put({"type": "workflow_status", "status": "stopped"})
                    wf["output_queue"].put({"type": "done"})
                    self.send_json({"status": "stopped"})
                else:
                    self.send_json({"error": "Workflow not found"}, 404)

        elif parsed.path == "/api/workflows":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            action = data.get("action", "")

            wf_file = os.path.join(BASE_DIR, "workflows.json")

            if action == "save":
                workflows = data.get("workflows", [])
                with open(wf_file, "w") as f:
                    json.dump(workflows, f, indent=2)
                self.send_json({"status": "saved", "count": len(workflows)})

            elif action == "load":
                if os.path.exists(wf_file):
                    with open(wf_file, "r") as f:
                        workflows = json.load(f)
                    self.send_json({"workflows": workflows})
                else:
                    self.send_json({"workflows": []})
            else:
                self.send_json({"error": "Unknown action"}, 400)

        elif parsed.path == "/api/custom-agents":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            action = data.get("action", "")

            agents_file = os.path.join(BASE_DIR, "custom-agents.json")

            if action == "save":
                agents = data.get("agents", [])
                with open(agents_file, "w") as f:
                    json.dump(agents, f, indent=2)
                self.send_json({"status": "saved", "count": len(agents)})

            elif action == "load":
                if os.path.exists(agents_file):
                    with open(agents_file, "r") as f:
                        agents = json.load(f)
                    self.send_json({"agents": agents})
                else:
                    self.send_json({"agents": []})
            else:
                self.send_json({"error": "Unknown action"}, 400)

        elif parsed.path == "/api/stop":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            agent_id = data.get("agent_id", "")

            with agent_lock:
                agent = active_agents.get(agent_id)
                if agent and agent["process"]:
                    agent["process"].terminate()
                    agent["status"] = "stopped"
                    self.send_json({"status": "stopped"})
                else:
                    self.send_json({"error": "Agent not found"}, 404)
        else:
            self.send_json({"error": "Not found"}, 404)

    def stream_sse(self, q):
        """Generic SSE streaming from a queue."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        while True:
            try:
                msg = q.get(timeout=30)
                event_data = json.dumps(msg)
                self.wfile.write(f"data: {event_data}\n\n".encode())
                self.wfile.flush()
                if msg.get("type") == "done":
                    break
            except queue.Empty:
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break

    def stream_agent(self, agent_id):
        with agent_lock:
            agent = active_agents.get(agent_id)
        if not agent:
            self.send_json({"error": "Agent not found"}, 404)
            return
        self.stream_sse(agent["output_queue"])

    def stream_workflow(self, wf_id):
        with workflow_lock:
            wf = active_workflows.get(wf_id)
        if not wf:
            self.send_json({"error": "Workflow not found"}, 404)
            return
        self.stream_sse(wf["output_queue"])

    def send_json(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def serve_html(self):
        html_path = os.path.join(BASE_DIR, "vibe-office.html")
        if os.path.exists(html_path):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            with open(html_path, "rb") as f:
                self.wfile.write(f.read())
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"""
            <html><body style="background:#0f0e17;color:#e2e8f0;font-family:monospace;padding:40px;text-align:center">
            <h1>Vibe Office</h1>
            <p>Run <code>./vibe-office.sh</code> first to generate the HTML, then refresh this page.</p>
            </body></html>
            """)


class ThreadedHTTPServer(HTTPServer):
    def process_request(self, request, client_address):
        thread = threading.Thread(target=self._handle, args=(request, client_address), daemon=True)
        thread.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    html_path = os.path.join(BASE_DIR, "vibe-office.html")
    script_path = os.path.join(BASE_DIR, "vibe-office.sh")
    if not os.path.exists(html_path) and os.path.exists(script_path):
        print("Generating vibe-office.html...")
        subprocess.run(["bash", script_path, html_path], check=True)

    server = ThreadedHTTPServer(("127.0.0.1", PORT), VibeHandler)
    print(f"\n  VIBE OFFICE SERVER")
    print(f"  Local:   http://localhost:{PORT}")
    print(f"  Claude:  {CLAUDE_BIN}")
    print(f"\n  Press Ctrl+C to stop\n")

    try:
        import webbrowser
        webbrowser.open(f"http://localhost:{PORT}")
    except Exception:
        pass

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
