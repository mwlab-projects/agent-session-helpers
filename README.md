# agent-session-helpers

Gestion de session (Claude Code / Codex / OpenCode) pour n'importe quel projet de développement — synchronisation git automatique, commit automatique, et skills de session.

## C'est quoi

Un ensemble de hooks et de skills qui connectent ton harnais IA (Claude Code, OpenAI Codex ou OpenCode) au workflow git de ton projet. Les 3 harnais partagent la même logique de session, portée par des scripts génériques dans `_system/` (source de vérité unique), chacun exposé via un adaptateur propre au harnais :

| Composant | Rôle |
|---|---|
| `_system/hooks/session_start_hook.sh` | Sync git auto au démarrage + injection d'un fichier de contexte (CHANGELOG.md par défaut) |
| `_system/hooks/stop_hook.sh` | Commit + push auto en fin de session (si `session_save` a été lancé), en ne stageant que les fichiers identifiés par le skill comme modifiés dans cette session |
| `_system/skills/session_save/` | Skill de fin de session : met à jour TODO.md / ARCHITECTURE.md / AGENTS.md / CHANGELOG.md, puis écrit le message de commit |
| `.claude/hooks`, `.claude/skills` | Symlinks vers `_system/hooks` et `_system/skills` — lus nativement par Claude Code |
| `.agents/skills` | Symlink vers `_system/skills` — lu nativement par Codex |
| `.codex/hooks.json` + `.codex/hooks/*.sh` | Déclaration des hooks Codex (SessionStart, Stop) + wrappers qui traduisent le JSON stdin/stdout attendu par Codex vers les scripts `_system/hooks/*.sh` |
| `.opencode/plugin/hub-sync.js` | Plugin OpenCode — équivalent fonctionnel des hooks via l'API de plugins JS (`session.created`, `experimental.chat.system.transform`, `tool.execute.after`), appelle les mêmes scripts `_system/hooks/*.sh` |

**Pourquoi :** un agent IA repart de zéro à chaque session — sans mémoire de ce qui a été fait avant. Ce système injecte automatiquement le contexte du projet au démarrage, maintient les fichiers de documentation à jour via `/session_save`, et commit + push en fin de session sans intervention manuelle — quel que soit le harnais utilisé.

## Comment installer

Donne l'URL de cette page à ton agent IA et demande-lui de suivre le guide d'installation ci-dessous.

---

## Guide d'installation (pour l'agent IA)

> Tu vas installer le système agent-session-helpers dans un projet, pour un ou plusieurs harnais (Claude Code, Codex, OpenCode). Suis chaque étape dans l'ordre.

### Prérequis

- Le projet doit être un dépôt git avec un remote configuré (`git remote -v` doit retourner quelque chose).
- Tu dois avoir les droits d'écriture sur le remote.

### Étape 1 — Créer la structure `_system/`

```bash
mkdir -p _system/hooks _system/skills/session_save
```

### Étape 2 — Récupérer et copier les hooks (source de vérité)

Récupère les deux fichiers de hook depuis ce dépôt et écris-les dans `_system/hooks/` :

- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/_system/hooks/stop_hook.sh` → `_system/hooks/stop_hook.sh`
- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/_system/hooks/session_start_hook.sh` → `_system/hooks/session_start_hook.sh`

Rends-les exécutables :

```bash
chmod +x _system/hooks/stop_hook.sh _system/hooks/session_start_hook.sh
```

**Optionnel :** ouvre `_system/hooks/session_start_hook.sh` et modifie la variable `CONTEXT_FILE` (ligne ~14) pour choisir le fichier injecté au démarrage de session. Défaut : `CHANGELOG.md`. Autres options : `README.md`, `TODO.md`, ou n'importe quel autre fichier.

### Étape 3 — Copier les skills

Récupère et écris :

- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/_system/skills/session_save/SKILL.md` → `_system/skills/session_save/SKILL.md`

### Étape 4 — Brancher Claude Code (si utilisé)

```bash
mkdir -p .claude
ln -s ../_system/hooks .claude/hooks
ln -s ../_system/skills .claude/skills
```

Récupère et écris `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/settings.json` → `.claude/settings.json` (déclare les hooks SessionStart/Stop et les permissions `Skill(session_save)`).

### Étape 5 — Brancher Codex (si utilisé)

```bash
mkdir -p .agents .codex/hooks
ln -s ../_system/skills .agents/skills
```

Récupère et écris :

- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/.codex/hooks.json` → `.codex/hooks.json`
- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/.codex/hooks/codex_session_start.sh` → `.codex/hooks/codex_session_start.sh`
- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/.codex/hooks/codex_stop.sh` → `.codex/hooks/codex_stop.sh`

```bash
chmod +x .codex/hooks/codex_session_start.sh .codex/hooks/codex_stop.sh
```

⚠️ **Trust Codex** : Codex n'exécute un hook que si deux niveaux de trust sont accordés, tous deux silencieux quand ils manquent (aucun warning) :
1. Trust du dossier projet côté config utilisateur Codex.
2. Trust par hook (hash exact de `hooks.json`) — seul le CLI interactif affiche le prompt "Hooks need review" ("Trust all and continue" ou `/hooks`). L'app desktop ne l'affiche jamais.

**Conséquence :** le premier trust doit toujours se faire en lançant `codex` en CLI interactif dans le projet. Une fois accordé, c'est persisté côté utilisateur et partagé avec l'app desktop.

### Étape 6 — Brancher OpenCode (si utilisé)

```bash
mkdir -p .opencode/plugin
```

Récupère et écris `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/.opencode/plugin/hub-sync.js` → `.opencode/plugin/hub-sync.js`.

Rien d'autre à faire : OpenCode charge automatiquement les plugins présents dans `.opencode/plugin/` et lit `AGENTS.md` + `.claude/skills`/`.agents/skills` nativement.

### Étape 7 — Créer les quatre fichiers de documentation projet

Ces fichiers sont le socle du système de session. Génère leur contenu en fonction du projet courant.

**`AGENTS.md`** — Instructions projet pour l'agent IA. Doit inclure :
- Une section **"Fichiers de documentation du projet"** listant AGENTS.md, ARCHITECTURE.md, TODO.md, CHANGELOG.md
- Une section **"Cycle de session"** : hook SessionStart → travail → `/session_save` → hook Stop
- Présentation du projet (ce que c'est, URL du repo, qui l'utilise)
- Stack technique
- Règles de dev (conventions de langue, contraintes clés)
- Commandes de build/lancement
- Une section **"Workflow"** incluant : "Proposer `/session_save` à la fin de chaque tâche — ne jamais l'invoquer automatiquement"

**`ARCHITECTURE.md`** — Architecture technique du projet (composants, flux de données, fichiers clés, stack).

**`TODO.md`** — Suivi des tâches et bugs. Format suggéré :

```markdown
# TODO — [Nom du projet]

## Vue d'ensemble

| ID | Titre | Statut | Prochaine action |
|----|-------|--------|------------------|
| [FEAT-1](#feat-1--titre) | Titre de la feature | ✅ Livré | - |
| [FEAT-2](#feat-2--titre) | Titre de la feature | 🟡 En cours — description courte | Prochaine étape concrète |
| [BUG-1](#bug-1--titre) | Titre du bug | 🟡 Root cause identifiée — fix en attente de validation | Valider le fix |
| [BUG-2](#bug-2--titre) | Titre du bug | ⚪ Archivé (disprouvé) | Aucune |

Légende : ✅ Validé · 🟡 En cours / en attente · ⚪ Archivé / backlog · 🔴 Bloqué

---

## FEAT-1 — Titre

[Description détaillée...]

## BUG-1 — Titre

[Description détaillée, root cause, logs...]
```

**`CHANGELOG.md`** — Historique des versions. Format suggéré :

```markdown
# Changelog

Format : [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/)
Versioning : +0.1 par version, entier suivant pour les refontes majeures.

## [Unreleased]

## [x.y.z] - YYYY-MM-DD

### Added
- ...

### Fixed
- ...
```

### Étape 8 — Créer `.claude/settings.local.json` (non versionné, Claude Code uniquement)

Ce fichier contient les permissions Bash par machine. Il est exclu de git par le gitignore global de Claude Code (`.config/git/ignore`), donc chaque utilisateur le crée pour lui-même.

Crée `.claude/settings.local.json` avec les permissions adaptées au stack du projet. Exemple :

```json
{
  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(npm *)",
      "Bash(node *)",
      "Bash(grep:*)",
      "Bash(find:*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(chmod:*)",
      "WebSearch",
      "WebFetch",
      "Write(session_commit_msg.txt)",
      "Write(session_commit_files.txt)"
    ]
  }
}
```

Adapte la liste à ton stack (remplace `npm` par `cargo`, `go`, `python`, etc. selon le projet).

### Étape 9 — `.gitignore` et commit

Ajoute au `.gitignore` :

```
session_commit_msg.txt
session_commit_files.txt

# OpenCode runtime cache/server files — only the plugin is versioned
.opencode/**
!.opencode/plugin/
!.opencode/plugin/**
```

Puis commite (en fonction des harnais réellement branchés aux étapes 4-6) :

```bash
git add AGENTS.md ARCHITECTURE.md TODO.md CHANGELOG.md .gitignore \
  _system/hooks _system/skills \
  .claude/settings.json .claude/hooks .claude/skills \
  .agents/skills .codex .opencode/plugin
git commit -m "chore: add multi-agent session management (agent-session-helpers)"
git push
```

> `.claude/settings.local.json` est intentionnellement exclu de ce commit — il est spécifique à chaque machine.

### Étape 10 — Redémarrer / relancer chaque harnais branché

⚠️ **Claude Code** : redémarre VS Code avant de tester — les hooks sont chargés au démarrage.
⚠️ **Codex** : lance `codex` en CLI interactif au moins une fois pour accorder le trust (voir Étape 5).
⚠️ **OpenCode** : relance le serveur/TUI pour qu'il recharge les plugins.

### Étape 11 — Vérifier

1. Ouvre le projet — le hook/plugin SessionStart doit tourner, synchroniser git et injecter le fichier de contexte.
2. Fais une modification, puis lance `/session_save` — il doit mettre à jour les fichiers doc et écrire `session_commit_msg.txt`.
3. Attends la fin de la réponse de l'agent — le hook/plugin Stop doit commiter et pusher automatiquement.
4. Vérifie sur GitHub que le commit apparaît.

---

## Référence des skills

### `/session_save`

Se lance en fin de session de travail. Demande confirmation, puis :
1. Met à jour `TODO.md` (nouvelles tâches, changements de statut avec confirmation utilisateur)
2. Met à jour `ARCHITECTURE.md` (si l'architecture a changé)
3. Propose des mises à jour de `AGENTS.md` (règles permanentes, confirmation requise)
4. Ajoute les entrées de la session dans `CHANGELOG.md [Unreleased]`
5. Consolide le scope de commit : liste les fichiers modifiés par cette session précise, demande confirmation pour tout fichier détecté hors scope (probable session parallèle), écrit `session_commit_files.txt`
6. Écrit `session_commit_msg.txt` — le hook/plugin Stop récupère les deux fichiers, ne stage que les fichiers listés (jamais un `git add -A` aveugle) et commite
