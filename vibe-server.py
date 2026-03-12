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


def parse_stream_event(line, q):
    """Parse a stream-json line from claude CLI and emit UI-friendly events."""
    try:
        evt = json.loads(line)
    except json.JSONDecodeError:
        q.put({"type": "raw", "data": line})
        return

    evt_type = evt.get("type", "")

    if evt_type == "system" and evt.get("subtype") == "init":
        q.put({
            "type": "init",
            "model": evt.get("model", ""),
            "tools": evt.get("tools", []),
            "session_id": evt.get("session_id", ""),
            "mcp_servers": evt.get("mcp_servers", []),
        })

    elif evt_type == "assistant":
        msg = evt.get("message", {})
        content_blocks = msg.get("content", [])

        for block in content_blocks:
            if block.get("type") == "text":
                text = block.get("text", "")
                if text.strip():
                    q.put({"type": "text", "data": text})

            elif block.get("type") == "tool_use":
                tool_name = block.get("name", "unknown")
                tool_input = block.get("input", {})
                tool_id = block.get("id", "")

                # Build a human-readable summary
                summary = summarize_tool_call(tool_name, tool_input)

                q.put({
                    "type": "tool_call",
                    "tool": tool_name,
                    "summary": summary,
                    "input": truncate_obj(tool_input, 300),
                    "tool_id": tool_id,
                })

            elif block.get("type") == "tool_result":
                tool_id = block.get("tool_use_id", "")
                content = block.get("content", "")
                if isinstance(content, list):
                    content = " ".join(
                        c.get("text", "") for c in content if c.get("type") == "text"
                    )
                q.put({
                    "type": "tool_result",
                    "tool_id": tool_id,
                    "result": str(content)[:500],
                })

    elif evt_type == "result":
        result_text = evt.get("result", "")
        cost = evt.get("total_cost_usd", 0)
        duration = evt.get("duration_ms", 0)
        num_turns = evt.get("num_turns", 0)

        q.put({
            "type": "result",
            "data": result_text,
            "cost": cost,
            "duration_ms": duration,
            "num_turns": num_turns,
        })


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


def run_agent(agent_id, prompt):
    """Run claude CLI with stream-json output and parse events."""
    agent = active_agents[agent_id]
    q = agent["output_queue"]

    try:
        agent["status"] = "running"
        q.put({"type": "status", "status": "running"})

        clean_env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
        clean_env["NO_COLOR"] = "1"

        proc = subprocess.Popen(
            [CLAUDE_BIN, "-p", prompt, "--output-format", "stream-json", "--verbose"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=clean_env,
        )
        agent["process"] = proc

        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            parse_stream_event(line, q)

        proc.wait()
        exit_code = proc.returncode

        # Capture any stderr
        stderr_out = proc.stderr.read()
        if stderr_out and stderr_out.strip():
            q.put({"type": "stderr", "data": stderr_out.strip()[:500]})

        agent["status"] = "done" if exit_code == 0 else "error"
        q.put({"type": "status", "status": agent["status"], "exit_code": exit_code})

    except Exception as e:
        agent["status"] = "error"
        q.put({"type": "error", "data": str(e)})

    q.put({"type": "done"})


class VibeHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/" or parsed.path == "/index.html":
            self.serve_html()
        elif parsed.path == "/api/status":
            self.send_json({"status": "ok", "claude_bin": CLAUDE_BIN, "active_agents": len(active_agents)})
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
                }

            thread = threading.Thread(target=run_agent, args=(agent_id, full_prompt), daemon=True)
            thread.start()

            self.send_json({"agent_id": agent_id, "status": "starting"})

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

    def stream_agent(self, agent_id):
        with agent_lock:
            agent = active_agents.get(agent_id)

        if not agent:
            self.send_json({"error": "Agent not found"}, 404)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        q = agent["output_queue"]
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

    def send_json(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def serve_html(self):
        html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibe-office.html")
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
    html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibe-office.html")
    script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibe-office.sh")
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
