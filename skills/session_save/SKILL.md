---
name: session_save
description: Sauvegarde de session de travail — vérifie TODO.md/ARCHITECTURE.md/CLAUDE.md, met à jour CHANGELOG.md (Unreleased), commit+push via le hook Stop. À proposer après chaque tâche de dev, ne pas invoquer automatiquement.
allowed-tools: Read, Write, Edit, Bash, Glob
---

# RÔLE

Agis en tant que gestionnaire de fin de session de travail.

# CONTEXTE D'UTILISATION

À lancer à la demande de l'utilisateur après une tâche de dev.

# OBJECTIF

Mettre à jour les fichiers contexte impactés par les modifications de la session courante et préparer le commit.

# CONTRAINTES

- Exécuter les étapes en silence — pas d'annonce intermédiaire, sauf pour les
  propositions nécessitant une confirmation (étapes 1 et 3)
- Ne jamais passer un statut de tâche/bug à "résolu"/"validé" dans TODO.md sans
  confirmation séparée de l'utilisateur (il doit avoir testé et validé)
- Ne jamais modifier CLAUDE.md sans confirmation séparée de l'utilisateur

# INSTRUCTIONS

0. **Gate de confirmation** : vérifier si l'utilisateur a déjà explicitement confirmé
   le lancement de `session_save` dans la conversation courante (ex : "yes",
   "oui", "go", "lance", "confirme"…)
   - Si oui → passer à l'étape 1
   - Si non → afficher "Lancer `session_save` pour clôturer la session ?" et
     attendre une réponse affirmative
     - Si réponse non affirmative ou absente → arrêter immédiatement sans rien
       modifier

   Cette confirmation vaut validation pour les étapes 1, 2, 4 et 5 (mise à jour du
   CHANGELOG et commit+push automatique via le hook `Stop`). L'étape 3 (CLAUDE.md)
   nécessite sa propre confirmation séparée.

## Étape 1 — Vérification TODO.md

1. Identifier les tâches/bugs de `TODO.md` concernés par les changements de la
   session (`git diff`, contexte de conversation)

2. Mettre à jour directement les éléments qui ne nécessitent pas de validation
   utilisateur :
   - Hypothèses et analyses enrichies pendant la session
   - Colonne "Prochaine action" si elle a évolué
   - Nouveaux bugs/tâches découverts, ajoutés au tableau et détaillés si besoin
   - Mention de logs de diagnostic ajoutés/retirés pendant la session

3. Pour tout changement de statut vers "résolu"/"validé" (nécessite que
   l'utilisateur ait testé) : lister les changements proposés et attendre une
   confirmation séparée avant de les appliquer. Si refusé ou pas de réponse,
   laisser le statut existant inchangé.

## Étape 2 — Vérification ARCHITECTURE.md

4. Identifier si la session a modifié l'architecture du projet : nouveau
   composant/service, nouvelle dépendance externe, nouveau pattern d'extension

5. Si oui → mettre à jour la section concernée pour refléter l'état actuel —
   sans historique, sans date, sans mention de ce qui a changé

6. Si non → ne rien faire

## Étape 3 — Proposition de mise à jour CLAUDE.md

7. Évaluer si la session révèle qu'une règle permanente devrait être ajoutée ou
   mise à jour dans `CLAUDE.md` :
   - **Convention de code** : nouveau pattern adopté
   - **Commande de build/test** : nouvelle commande découverte ou changée
   - **Documentation** : nouveau fichier de doc à référencer dans les "Fichiers de
     documentation du projet"
   - **Stack technique** : changement de version majeure ou de deployment target,
     nouvelle dépendance majeure
   - **Règle de workflow** : une règle qui, si présente, aurait évité une question,
     une hésitation ou une erreur pendant la session

   Ne qualifie pas :
   - Info spécifique à un bug ou à l'état d'avancement → `TODO.md`
   - Changement d'architecture du système → `ARCHITECTURE.md`
   - Changement livré à l'utilisateur final → `CHANGELOG.md`

8. Si au moins un élément qualifie : afficher une proposition avec justification et
   attendre la confirmation de l'utilisateur — séparée du gate de l'étape 0
   - Si confirmé → modifier `CLAUDE.md` en conséquence
   - Si non confirmé ou pas de réponse → ne rien modifier

## Étape 4 — Mise à jour CHANGELOG.md

9. Lire `CHANGELOG.md`

10. Sous `## [Unreleased]`, ajouter les entrées de la session catégorisées au format
    Keep a Changelog (`### Added`, `### Changed`, `### Fixed`, `### Removed`,
    etc. — créer la sous-section si elle n'existe pas encore)

11. Bullets concis, orientés utilisateur final (pas de détails d'implémentation
    internes type noms de fonctions/fichiers)

## Étape 5 — Message de commit

12. Écrire avec l'outil **Write** (pas Bash) dans `.claude/session_commit_msg.txt` :
    - Ligne 1 : `type: résumé court` au format Conventional Commits, cohérent avec
      l'historique du repo (`fix:`, `feat:`, `docs:`, `chore:`, etc.) — déterminer
      le type dominant à partir des changements de code de la session ; si la
      session n'a touché que la documentation → `docs:`
    - Ligne 2 : vide (séparateur git titre/corps)
    - Ligne 3+ : bullets reprenant les entrées ajoutées au CHANGELOG, plus une
      mention des fichiers doc mis à jour (TODO.md/ARCHITECTURE.md/CLAUDE.md si
      modifiés)
    - ⛔ Ne pas exécuter `git add`, `git commit` ou `git push` — le hook `Stop` s'en
      charge automatiquement
    - Afficher : "Session sauvegardée 👍"

## Étape 6 — Definition of Done

13. Valider chaque point, corriger immédiatement tout point non respecté :
    - `TODO.md` à jour (hors statuts "résolu" en attente de confirmation séparée)
    - `ARCHITECTURE.md` à jour si un changement d'architecture a été identifié
    - `CLAUDE.md` mis à jour uniquement si l'utilisateur a confirmé la proposition
      de l'étape 3
    - `CHANGELOG.md` `[Unreleased]` contient les entrées de la session
    - `.claude/session_commit_msg.txt` écrit
