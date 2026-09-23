# agent-session-helpers

Gestion de session Claude Code pour n'importe quel projet de développement — synchronisation git automatique, commit automatique, et skills de session.

## C'est quoi

Un ensemble de hooks et de skills qui connectent Claude Code au workflow git de ton projet :

| Composant | Rôle |
|---|---|
| `hooks/session_start_hook.sh` | Sync git auto au démarrage + injection d'un fichier de contexte (CHANGELOG.md par défaut) |
| `hooks/stop_hook.sh` | Commit + push auto en fin de session (si `session_save` a été lancé), en ne stageant que les fichiers identifiés par le skill comme modifiés dans cette session |
| `skills/session_save/` | Skill de fin de session : met à jour TODO.md / ARCHITECTURE.md / AGENTS.md / CHANGELOG.md, puis écrit le message de commit |
| `skills/session_handoff/` | Crée un fichier handoff autonome pour passer la main à un autre agent ou une autre session |

**Pourquoi :** Claude Code repart de zéro à chaque session — sans mémoire de ce qui a été fait avant. Ce système injecte automatiquement le contexte du projet au démarrage, maintient les fichiers de documentation à jour via `/session_save`, et commit + push en fin de session sans intervention manuelle.

## Comment installer

Donne l'URL de cette page à Claude Code et demande-lui de suivre le guide d'installation ci-dessous.

---

## Guide d'installation (pour Claude Code)

> Tu vas installer le système agent-session-helpers dans un projet. Suis chaque étape dans l'ordre.

### Prérequis

- Le projet doit être un dépôt git avec un remote configuré (`git remote -v` doit retourner quelque chose).
- Tu dois avoir les droits d'écriture sur le remote.

### Étape 1 — Créer la structure `.claude/`

```bash
mkdir -p .claude/hooks .claude/skills/session_save .claude/skills/session_handoff
```

### Étape 2 — Récupérer et copier les hooks

Récupère les deux fichiers de hook depuis ce dépôt et écris-les dans `.claude/hooks/` :

- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/hooks/stop_hook.sh` → `.claude/hooks/stop_hook.sh`
- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/hooks/session_start_hook.sh` → `.claude/hooks/session_start_hook.sh`

Rends-les exécutables :

```bash
chmod +x .claude/hooks/stop_hook.sh .claude/hooks/session_start_hook.sh
```

**Optionnel :** ouvre `.claude/hooks/session_start_hook.sh` et modifie la variable `CONTEXT_FILE` (ligne ~14) pour choisir le fichier injecté au démarrage de session. Défaut : `CHANGELOG.md`. Autres options : `README.md`, `TODO.md`, ou n'importe quel autre fichier.

### Étape 3 — Copier les skills

Récupère et écris :

- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/skills/session_save/SKILL.md` → `.claude/skills/session_save/SKILL.md`
- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/skills/session_handoff/SKILL.md` → `.claude/skills/session_handoff/SKILL.md`

### Étape 4 — Créer `.claude/settings.json`

Récupère et écris :

- `https://raw.githubusercontent.com/bloculus/agent-session-helpers/main/settings.json` → `.claude/settings.json`

### Étape 5 — Créer les quatre fichiers de documentation projet

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

### Étape 6 — Créer `.claude/settings.local.json` (non versionné)

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

### Étape 7 — Commiter tout

Ajoute `session_commit_msg.txt` et `session_commit_files.txt` au `.gitignore` — ces fichiers sont les déclencheurs temporaires du hook Stop, ils ne doivent pas être versionnés :

```bash
printf "session_commit_msg.txt\nsession_commit_files.txt\n" >> .gitignore
git add AGENTS.md ARCHITECTURE.md TODO.md CHANGELOG.md .gitignore .claude/settings.json .claude/hooks/ .claude/skills/
git commit -m "chore: add Claude Code session management (agent-session-helpers)"
git push
```

> `.claude/settings.local.json` est intentionnellement exclu de ce commit — il est spécifique à chaque machine.

### Étape 8 — Redémarrer VS Code

⚠️ **Redémarre VS Code** avant de tester. Claude Code charge les hooks au démarrage — sans redémarrage après l'installation, le hook Stop ne se déclenchera pas.

### Étape 9 — Vérifier

1. Ouvre le projet dans Claude Code — le hook SessionStart doit tourner, synchroniser git et injecter le fichier de contexte.
2. Fais une modification, puis lance `/session_save` — il doit mettre à jour les fichiers doc et écrire `session_commit_msg.txt`.
3. Attends la fin de la réponse de Claude — le hook Stop doit commiter et pusher automatiquement (pas besoin de fermer la fenêtre).
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
6. Écrit `session_commit_msg.txt` — le hook Stop récupère les deux fichiers, ne stage que les fichiers listés (jamais un `git add -A` aveugle) et commite

### `/session_handoff`

Crée un fichier `handoff_YYMMDD_[theme].md` autonome à la racine du projet. Un agent démarrant à froid peut le lire et reprendre sans avoir accès à l'historique de conversation. Gère aussi le chargement d'un handoff existant (Mode REPRISE).
