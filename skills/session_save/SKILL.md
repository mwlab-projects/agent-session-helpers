---
name: session_save
description: Sauvegarde de session de travail — vérifie TODO.md/ARCHITECTURE.md/CLAUDE.md, met à jour CHANGELOG.md (Unreleased), consolide le scope de commit à la session courante, commit+push via le hook Stop. À proposer après chaque tâche de dev, ne pas invoquer automatiquement.
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
- Interdiction de laisser une ligne "Issues connues"/tâche ouverte pour le sujet
  traité pendant la session courante si l'utilisateur n'a pas explicitement
  confirmé si ce sujet est clos ou encore en cours — sans cette confirmation
  précise dans la conversation, poser la question (étape 1) au lieu de deviner
  ou d'ajouter une ligne "à valider" par précaution
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

   Cette confirmation vaut validation pour les étapes 1, 2, 4, 5 et 6 (mise à jour du
   CHANGELOG, consolidation du scope de commit et commit+push automatique via le hook
   `Stop`). L'étape 3 (CLAUDE.md) nécessite sa propre confirmation séparée.

## Étape 1 — Vérification TODO.md

1. Identifier les fichiers locaux modifiés pendant la session à partir du contexte
   de conversation, en excluant `TODO.md`, `ARCHITECTURE.md`, `CLAUDE.md` et
   `CHANGELOG.md` (mis à jour conditionnellement par les étapes suivantes de ce
   skill — traités séparément à l'étape de consolidation du scope de commit)

2. Identifier les tâches/bugs de `TODO.md` concernés par les changements de la
   session (`git diff`, contexte de conversation)

3. Mettre à jour directement les éléments qui ne nécessitent pas de validation
   utilisateur :
   - Hypothèses et analyses enrichies pendant la session
   - Colonne "Prochaine action" si elle a évolué
   - Nouveaux bugs/tâches découverts qui sont clairement distincts du sujet
     traité cette session (limitation constatée en passant, jamais discutée
     comme "à corriger maintenant") : ajoutés au tableau et détaillés si besoin
   - Mention de logs de diagnostic ajoutés/retirés pendant la session
   - Toute tâche/bug déjà attesté comme fonctionnel dans la conversation
     courante (l'utilisateur a confirmé que ça marche) : retirer directement
     la ligne du tableau, sans reposer la question

4. Pour le sujet précis traité pendant la session courante (le fix/la feature
   qui vient d'être fait) : ne mettre à jour `TODO.md` sur ce sujet que si
   l'utilisateur a confirmé explicitement s'il est clos ou encore en cours. Si
   cette confirmation est déjà dans la conversation, l'appliquer directement
   (retirer la ligne si clos, la garder/la détailler si encore en cours) sans
   reposer la question. Sinon, poser directement la question avant de toucher
   à `TODO.md` sur ce point (ex : "Le sujet sur lequel on travaillait est-il
   terminé et validé ?"). Pour toute autre ligne préexistante du tableau dont
   le statut n'est pas clair : lister les changements proposés et attendre une
   confirmation séparée avant de les appliquer — si refusé ou pas de réponse,
   laisser le statut existant inchangé.

## Étape 2 — Vérification ARCHITECTURE.md

5. Identifier si la session a modifié l'architecture du projet : nouveau
   composant/service, nouvelle dépendance externe, nouveau pattern d'extension

6. Si oui → mettre à jour la section concernée pour refléter l'état actuel, en
   1-3 lignes par composant touché, éditée en place (jamais en ajout de
   paragraphe) — sans historique, sans date, sans mention de ce qui a changé

   Ne jamais inclure dans ARCHITECTURE.md (même si ça a occupé une bonne partie
   de la session) :
   - Récit de bug/diagnostic ou étapes de découverte ("confirmé par test",
     "découvert en usage réel")
   - Alternative essayée puis abandonnée, avec son détail d'échec
   - Valeur de tuning précise (délai ms, seuil px, couleur) sauf si l'ignorer
     casserait silencieusement un autre composant
   - Toute mention de validation/confirmation utilisateur

   Si le seul élément notable de la session est un "pourquoi non-obvious"
   local à un seul fichier (pas un invariant cross-fichiers) : ça va dans un
   commentaire de code à cet endroit, pas dans ARCHITECTURE.md. Point — pas
   d'entrée doc en plus, pas de mention à l'utilisateur.

7. Si non → ne rien faire

## Étape 3 — Proposition de mise à jour CLAUDE.md

8. Évaluer si la session révèle qu'une règle permanente devrait être ajoutée ou
   mise à jour dans `CLAUDE.md`. Ne proposer que si les 3 conditions suivantes
   sont TOUTES réunies :
   - Ça a réellement coûté du temps cette session (plusieurs allers-retours,
     un bug difficile à tracer) — pas juste "bon à savoir en passant"
   - Ça a de fortes chances de refrapper sur un **composant différent** dans
     une session future — pas un détail qu'on retrouverait en 30 secondes en
     relisant la doc officielle de l'outil/l'API au moment voulu (ex : un
     paramètre d'API tierce isolé ne qualifie pas à lui seul)
   - Ce n'est pas déjà couvert, même implicitement, ailleurs dans `CLAUDE.md`
     — que ce soit une règle existante ou un fait déjà énoncé dans une autre
     section

   Ne qualifient jamais :
   - Info spécifique à un bug ou à l'état d'avancement → `TODO.md`
   - Changement d'architecture du système → `ARCHITECTURE.md`
   - Changement livré à l'utilisateur final → `CHANGELOG.md`
   - Une astuce d'API tierce sans impact architectural direct et récurrent sur
     ce projet
   - Un fait/une propriété d'architecture sans consigne de comportement
     associée ("X est toujours vrai") → `ARCHITECTURE.md`, pas `CLAUDE.md`
     (`CLAUDE.md` dit quoi faire, pas ce qui est)

9. Si au moins un élément qualifie : afficher une proposition avec justification et
   attendre la confirmation de l'utilisateur — séparée du gate de l'étape 0
   - Si confirmé → modifier `CLAUDE.md` en conséquence, en respectant
     strictement le format ci-dessous
   - Si non confirmé ou pas de réponse → ne rien modifier

   **Format obligatoire de toute puce ajoutée à `CLAUDE.md`** — gabarit à
   suivre : `**Titre court**` : ce qu'il faut faire/éviter — pourquoi
   (mécanisme technique général, pas l'incident précis).

   ⚠️ CLAUDE.md n'est pas un journal de bord : une puce n'énonce QUE la règle
   et son mécanisme, jamais l'aventure qui a mené à la découvrir. Ne jamais
   inclure :
   - Récit de bug/diagnostic ou étapes de découverte ("vécu :", "constaté
     que", "a concrètement échoué sur X")
   - Alternative essayée puis abandonnée, avec son détail d'échec (tickets
     cités un par un, historique de tentatives)
   - Mention de validation/confirmation utilisateur
   - Valeur de tuning précise (délai ms, seuil px, couleur) sauf si l'ignorer
     casserait silencieusement un autre composant

   Ce récit va dans le message de commit de cette session (étape 6), jamais
   dans `CLAUDE.md`.

## Étape 4 — Mise à jour CHANGELOG.md

10. Lire `CHANGELOG.md`

11. Sous `## [Unreleased]`, ajouter les entrées de la session catégorisées au format
    Keep a Changelog (`### Added`, `### Changed`, `### Fixed`, `### Removed`,
    etc. — créer la sous-section si elle n'existe pas encore)

12. Bullets concis, orientés utilisateur final (pas de détails d'implémentation
    internes type noms de fonctions/fichiers)

## Étape 5 — Consolidation du scope de commit

13. Construire la liste des fichiers locaux modifiés par CETTE session : fusion des
    fichiers identifiés à l'étape 1 avec tout fichier de doc effectivement édité par
    le skill lui-même aux étapes 2 à 4 (`TODO.md`, `ARCHITECTURE.md`, `CLAUDE.md`,
    `CHANGELOG.md`) et tout autre fichier local édité en session dont tu as
    connaissance.

14. Exécuter `git status --porcelain=v1 --no-renames -z | while IFS= read -r -d '' entry; do printf '%s\n' "${entry:3}"; done`
    (Bash) pour obtenir les chemins modifiés/non trackés, un par ligne, sans code de statut ni
    échappement (`--no-renames` + `-z` évitent respectivement la fusion `ancien -> nouveau` sur
    une seule ligne et l'échappement octal des noms de fichiers accentués).
    Comparer avec la liste de l'étape 13 :
    - Si tous les chemins obtenus sont couverts par la liste → passer à l'étape 15
      sans rien demander
    - Si des chemins apparaissent en dehors de la liste (probable session parallèle
      en cours) → les présenter à l'utilisateur (liste numérotée, langage non
      technique) pour demander s'ils doivent être intégrés à la sauvegarde. Exemple :
      ```
      D'autres fichiers modifiés ont été détectés en dehors de cette session,
      probablement une autre session en cours :
      1) `Sources/Foo.swift`
      2) `CHANGELOG.md`

      Je les inclus dans la sauvegarde ?
      ```
      Attendre une réponse. Sans confirmation explicite, ne jamais les inclure.

15. Écrire la liste finale (fichiers de l'étape 13 + fichiers confirmés à l'étape 14)
    dans `session_commit_files.txt` (racine du repo), un chemin par ligne, avec
    l'outil **Write**.

## Étape 6 — Message de commit

16. Écrire avec l'outil **Write** (pas Bash) dans `session_commit_msg.txt` (racine
    du repo) :
    - Ligne 1 : `type: résumé court` au format Conventional Commits, cohérent avec
      l'historique du repo (`fix:`, `feat:`, `docs:`, `chore:`, etc.) — déterminer
      le type dominant à partir des changements de code de la session ; si la
      session n'a touché que la documentation → `docs:`
    - Ligne 2 : vide (séparateur git titre/corps)
    - Ligne 3+ : bullets reprenant les entrées ajoutées au CHANGELOG, plus une
      mention des fichiers doc mis à jour (TODO.md/ARCHITECTURE.md/CLAUDE.md si
      modifiés)
    - ⛔ Ne pas exécuter `git add`, `git commit` ou `git push` — le hook `Stop` s'en
      charge automatiquement, en se limitant aux fichiers listés dans
      `session_commit_files.txt` écrit à l'étape 15
    - Afficher : "Session sauvegardée 👍"

## Étape 7 — Definition of Done

17. Valider chaque point, corriger immédiatement tout point non respecté :
    - `TODO.md` à jour (hors statuts "résolu" en attente de confirmation séparée),
      aucune ligne "Issues connues"/tâche laissée ouverte pour le sujet de la
      session sans confirmation explicite de l'utilisateur sur son statut
    - `ARCHITECTURE.md` à jour si un changement d'architecture a été identifié
    - `CLAUDE.md` mis à jour uniquement si l'utilisateur a confirmé la proposition
      de l'étape 3
    - `CHANGELOG.md` `[Unreleased]` contient les entrées de la session
    - La liste des fichiers de commit a été consolidée (étapes 13-14) et les
      fichiers hors session, le cas échéant, soumis à confirmation avant inclusion
    - `session_commit_files.txt` et `session_commit_msg.txt` écrits (racine du
      repo — le hook se charge du reste)
