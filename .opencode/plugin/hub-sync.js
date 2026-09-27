import { execSync } from "child_process";
import path from "path";

export const HubSyncPlugin = async ({ directory }) => {
  // Sortie de session_start_hook.sh en attente d'injection, par sessionID — produite une seule
  // fois par "session.created" (nouvelle session réelle, jamais une reprise — même sémantique
  // que le matcher "startup" côté Claude Code), consommée et effacée au premier
  // "experimental.chat.system.transform" de cette session. Map plutôt qu'une simple variable :
  // évite toute fuite de contexte entre sessions concurrentes sur un serveur opencode persistant.
  const pendingSessionStart = new Map();

  return {
    // SessionStart (nouvelle session) — délègue entièrement à session_start_hook.sh : git sync
    // (fetch/rebase --autostash) + génération du texte à injecter (env, alerte de sync, git log),
    // dans l'ordre défini par le script lui-même (alerte avant le log — voir le script pour le
    // pourquoi : plafond de troncature des hooks).
    // "session.created" n'existe pas comme clé de hook directe dans l'API OpenCode :
    // seul le bus générique "event" reçoit les événements de session (type EventSessionCreated).
    event: async ({ event }) => {
      if (event.type !== "session.created") return;
      const sessionID = event.properties?.info?.id;
      if (!sessionID) return;
      try {
        const output = execSync(
          `bash "${path.join(directory, "_system/hooks/session_start_hook.sh")}"`,
          { cwd: directory, encoding: "utf-8" }
        );
        if (output && output.trim()) {
          pendingSessionStart.set(sessionID, output.trim());
        }
      } catch (_) {}
    },

    // SessionStart — injecte dans le system prompt la sortie produite ci-dessus pour cette
    // session, si présente (rien sur une reprise : pas d'entrée dans la Map, comme prévu).
    "experimental.chat.system.transform": async (input, output) => {
      const sessionID = input.sessionID;
      if (!sessionID) return;
      const content = pendingSessionStart.get(sessionID);
      if (content) {
        output.system.push(content);
        pendingSessionStart.delete(sessionID);
      }
    },

    // Commit + push dès que session_commit_msg.txt est écrit (write ou edit)
    "tool.execute.after": async (input) => {
      if (input.tool !== "write" && input.tool !== "edit") return;
      const fp = input.args?.filePath || "";
      if (!fp.endsWith("session_commit_msg.txt")) return;
      try {
        execSync(
          `bash "${path.join(directory, "_system/hooks/stop_hook.sh")}"`,
          { cwd: directory, stdio: "ignore" }
        );
      } catch (_) {}
    }
  };
};

export default HubSyncPlugin;
