---
name: session_handoff
description: Crée un fichier handoff à la racine du projet — synthèse de ce qui a été fait, résultats, état actuel et prochaines étapes — pour passer la main à un autre agent ou une autre session. À invoquer dès que : l'utilisateur demande un handoff / veut passer la main / dit "reprends depuis le handoff" avec un handoff existant.
allowed-tools: Read, Write, Bash
---

# RÔLE

Agis en tant que rédacteur de handoff de session. Tu synthétises l'état d'une session de travail dans un fichier autonome et actionnable, lisible par un agent démarrant à froid.

# CONTEXTE D'UTILISATION

Ce skill s'exécute dans une session avec un agent IA et opère en deux modes selon l'état de la session courante.

**Mode CRÉATION** (session active) : la conversation contient du travail accompli.
Le skill produit un fichier `handoff_YYMMDD_[theme].md` à la racine du projet, auto-suffisant pour permettre à un agent à froid de reprendre sans lire l'historique.

**Mode REPRISE** (session vierge) : aucun travail en cours dans la conversation.
L'utilisateur mentionne un handoff existant ou demande de reprendre depuis un handoff.
Le skill vérifie si le fichier existe à la racine du projet, demande confirmation avant de le charger, puis le supprime après chargement pour libérer le slot.

# OBJECTIF

- **Mode CRÉATION** : produire un fichier `handoff_YYMMDD_[theme].md` à la racine du projet
- **Mode REPRISE** : charger le contenu du handoff dans la session et supprimer le fichier

# CONTRAINTES

- Le fichier doit être **auto-suffisant** : un agent qui ne lit que ce fichier doit pouvoir agir sans accéder à l'historique de conversation
- Toujours écrire les chemins de fichiers en absolu depuis la racine du projet
- Ne jamais inventer ni supposer un résultat — si un résultat est incertain, le signaler avec ⚠️
- Ne pas commiter — laisser l'utilisateur décider (ou lancer `session_save` séparément)
- Si un handoff du même thème existe déjà aujourd'hui, l'écraser (même fichier)
- **Mode REPRISE** : ne jamais charger ni supprimer un handoff sans confirmation explicite de l'utilisateur

# INSTRUCTIONS

## Étape 0 — Détecter le mode

Évaluer silencieusement l'état de la session courante :

**Cas A — Session active** : la conversation contient du travail accompli (actions réalisées, fichiers modifiés, décisions prises).
→ Continuer directement vers **Étape 1 (Mode CRÉATION)**.

**Cas B — Session vierge** : aucun travail en cours, l'utilisateur mentionne un handoff ou demande de reprendre.
→ Passer directement à **Mode REPRISE** ci-dessous.

---

### Mode REPRISE

1. Lister les fichiers `handoff_*.md` à la racine du projet.

2. **Si aucun fichier trouvé** : afficher `Aucun handoff trouvé à la racine du projet.` et arrêter.

3. **Si un ou plusieurs fichiers trouvés** : les afficher à l'utilisateur et demander confirmation avant tout chargement.

4. Après confirmation :
   - Lire le contenu du fichier handoff et l'afficher dans la conversation section par section
   - Supprimer le fichier handoff
   - Afficher : `✅ Handoff chargé (fichier supprimé). Prêt à continuer.`

5. Valider chaque point de la Definition of Done, corriger immédiatement tout point non respecté :
   - La confirmation explicite de l'utilisateur a bien été obtenue avant chargement puis suppression
   - Le fichier handoff a été supprimé

---

## Confirmation et thème (Mode CRÉATION)

1. Vérifier si l'utilisateur a déjà explicitement demandé le handoff dans la conversation courante.
   - Si non → afficher "Lancer `session_handoff` ?" et attendre confirmation.
   - Si oui → continuer.

2. Identifier le thème en 1 mot (kebab-case, sans accents) :
   - Si l'utilisateur l'a fourni en argument → utiliser directement
   - Sinon → déduire du contenu de la session (ex. `restructuration`, `workflow`, `deploy`, `audit`)
   - En dernier recours → demander à l'utilisateur

## Collecte du contexte

3. Analyser la conversation courante pour extraire :
   - **L'objectif de la session** : pourquoi ce travail a été lancé
   - **Les actions réalisées** et leur résultat (✅ succès, ⚠️ partiel, ❌ échec)
   - **Les fichiers créés ou modifiés** (chemins exacts depuis la racine du projet)
   - **L'état actuel** : où en est-on maintenant, ce qui est en place
   - **Les prochaines étapes** : ce qui reste à faire, dans quel ordre
   - **Les points d'attention** : dépendances, bloquants, décisions en suspens, risques

## Obtenir la date

4. Obtenir la date du jour :
   ```bash
   date "+%y%m%d"
   ```

## Écrire le handoff

5. Construire le nom de fichier : `handoff_YYMMDD_[theme].md`

6. Écrire le fichier à la racine du projet avec la structure suivante :

```
# Handoff — [Titre lisible de la session]

**Date** : YYYY-MM-DD
**Thème** : [theme]
**Statut** : 🟡 En cours / 🟢 Prêt pour handoff / 🔴 Bloqué

---

## Contexte

[2-4 phrases expliquant pourquoi ce travail a été lancé, ce que l'on cherche à accomplir et pourquoi c'est important. Suffisant pour qu'un agent à froid comprenne l'enjeu sans lire l'historique.]

---

## Ce qui a été fait

[Ne conserve ici que ce qui est pertinent - retire toute action secondaire n'ayant pas d'impact sur l'objectif]

- [Action 1] — ✅/⚠️/❌ [résultat concret]
- [Action 2] — ✅/⚠️/❌ [résultat concret]
...


---

## État actuel

[Description précise de l'état du projet après cette session. Lister les fichiers créés/modifiés avec ce qu'il faut prendre en compte.]

**Fichiers créés/modifiés :**
- `[chemin]` — [Modifications + éventuels points d'attention]
...

---

## Prochaines étapes

[Étapes numérotées, actionnables, dans l'ordre. Inclure les commandes bash ou chemins exacts quand c'est utile.]

1. ...
2. ...
...

---

## Points d'attention

- [Bloquant, dépendance, décision en suspens, risque ou contrainte à ne pas oublier]
...
```

## Confirmation

7. Valider chaque point de la Definition of Done, corriger immédiatement tout point non respecté :
   - Le fichier `handoff_YYMMDD_[theme].md` existe à la racine du projet
   - Il est auto-suffisant : un agent à froid peut reprendre sans lire l'historique
   - Aucune information inventée ou supposée — tout est vérifiable ou marqué ⚠️
   - Afficher : `✅ Handoff créé : handoff_YYMMDD_[theme].md`
