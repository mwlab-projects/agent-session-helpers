import { execSync } from "child_process";
import fs from "fs";
import path from "path";

// OpenCode V2 plugin API: default export with { id, setup(ctx) }.
// The V1 API (named export returning a hooks object) silently does nothing in V2.
export default {
  id: "hub-sync",
  async setup(ctx) {
    const directory = ctx.location.directory;
    // session_start_hook.sh output queued per session, consumed once. Fed by the
    // "session.created" event (new sessions only, never a resume - same semantics
    // as the "startup" matcher on the Claude Code side).
    const pendingSessionStart = new Map();
    const controller = new AbortController();

    // SessionStart (new session): delegate to session_start_hook.sh - git sync
    // (sync_git_with_remote.sh) + context text generation, in the order defined by the script itself.
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          if (event.type !== "session.created") continue;
          // Encoded stream shape: event.data.sessionID (decoded SDK shape: properties.sessionID)
          const sessionID = event.data?.sessionID ?? event.properties?.sessionID;
          if (!sessionID || pendingSessionStart.has(sessionID)) continue;
          try {
            const output = execSync(
              `bash "${path.join(directory, "_system/hooks/session_start_hook.sh")}"`,
              { cwd: directory, encoding: "utf-8" }
            );
            if (output && output.trim()) pendingSessionStart.set(sessionID, output.trim());
          } catch (_) {}
        }
      } catch (_) {}
    })();

    // Inject the queued context into this session's system prompt, once (deleted
    // after first injection). "context" runs for the agent loop only, not for
    // title/compaction/generate auxiliary calls.
    await ctx.session.hook("context", (event) => {
      const content = pendingSessionStart.get(event.sessionID);
      if (content) {
        event.system.push({ type: "text", text: content });
        pendingSessionStart.delete(event.sessionID);
      }
    });

    // Stop: run stop_hook.sh (commit + push) as soon as a session commit is prepared, or while a
    // sync conflict is open (the hook finalizes it once an agent has resolved its files). The
    // _system folder is checked after every completed tool call, whatever the tool: this never
    // depends on how a given OpenCode version names a tool or its arguments.
    const sysDir = path.join(directory, "_system");
    const conflictState = path.join(sysDir, "sync_conflict", ".sync_conflict_state");
    await ctx.tool.hook("execute.after", (event) => {
      if (event.status !== "completed") return;
      try {
        if (
          !fs.readdirSync(sysDir).some((f) => /^session_commit_.*\.txt$/.test(f)) &&
          !fs.existsSync(conflictState)
        ) return;
        execSync(
          `bash "${path.join(directory, "_system/hooks/stop_hook.sh")}"`,
          { cwd: directory, stdio: "ignore" }
        );
      } catch (_) {}
    });

    // Cleanup: stop the event subscription when the plugin unloads.
    return () => controller.abort();
  },
};
