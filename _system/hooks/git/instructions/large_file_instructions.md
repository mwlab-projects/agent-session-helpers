Commit refusé pour cause de fichier(s) volumineux.

Suivre ces étapes :

1) Évaluer, pour chaque fichier, la recommandation à faire :
    - Ignorer la limite de taille et sauvegarder le fichier dans git, à sa place actuelle : uniquement s'il est nécessaire à cet emplacement pour qu'un système fonctionne (ex. une image chargée par une application, un modèle utilisé par un skill)
    - Sinon, le déplacer dans le dossier data/ (non suivi par git) à la racine du dépôt ou à un autre endroit si adapté (Google Drive, Dropbox...)
    - Dans tous les cas, choisir le dossier de data/ où il pourrait aller ([DOSSIER]) : suivre l'organisation déjà en place dans data/ (dossier existant pertinent, ou nouveau dossier cohérent avec les existants) ; si data/ ne contient aucun dossier, proposer par défaut `data/<Catégorie>/<année>/` (ex. data/Factures/2026/)

2) Expliquer simplement que le système a détecté **N fichier(s) volumineux** qui n'ont pas forcément besoin d'être dans git et qui alourdiraient la sauvegarde (si l'utilisateur est non-technique, préciser pourquoi c'est important de l'éviter). 
Inclure le texte ci-dessous (une ligne de tableau par fichier), puis attendre la réponse de l'utilisateur :
    ```
      | | Fichier | Taille | Recommandation |
    |---|---|---|---|
    | [N°] | [NOM DU FICHIER (sans chemin)] | [TAILLE] Mo | **[Numéro choix] - [Action]** : [raison courte sans jargon] |

    Que décides-tu ? 
    (Choix possibles : 
    **1.** Stocker le(s) fichier(s) dans `data/` (prévu à cet effet) · **2.** Ignorer la limite de taille et sauvegarder · **3.** Le(s) déplacer ailleurs (Google Drive, Dropbox...))
    ```

    Règles :
    - Accorder tout le message au singulier s'il n'y a qu'un seul fichier concerné, au pluriel sinon
    - Pour une recommandation de stocker le fichier dans `data/`, indiquer `[DOSSIER]` dans [Action] ; s'il n'existe pas encore, ajouter « (nouveau dossier) » après `[DOSSIER]`
    - Ne jamais ajouter de jargon technique (commit, hook, .gitattributes) → garder le vocabulaire du message

3) Attendre le choix de l'utilisateur pour chaque fichier, puis l'appliquer :
    - Choix 1 :
      - déplacer le(s) fichier(s) dans [DOSSIER], ou dans le dossier indiqué par l'utilisateur (toujours sous le dossier data/ à la racine du dépôt), sans le(s) renommer (ajouter -2, -3... avant l'extension si le nom existe déjà), puis mettre à jour tous les liens du dépôt qui renvoient vers le(s) fichier(s) (rechercher leur nom dans les fichiers texte du dépôt) pour qu'ils pointent vers le nouvel emplacement.
      - exécuter la commande de retrait indiquée pour chacun dans le bloc ci-dessus
    - Choix 2 :
      - ajouter au .gitattributes la ligne de laissez-passer indiquée pour chacun dans le bloc ci-dessus
    - Choix 3 :
      - aider l'utilisateur à déplacer le(s) fichier(s)
      - exécuter la commande de retrait indiquée pour chacun dans le bloc ci-dessus

4) Une fois tous les fichiers traités :
    - Si le refus est apparu pendant une sauvegarde ou un commit en cours :
      - relancer cette sauvegarde ou ce commit, en y ajoutant les fichiers modifiés à l'étape 3 et en retirant les fichiers déplacés (choix 1 ou 3)
    - Si le refus a été signalé au démarrage de la session (bloc [save] de session_error.log) :
      - ajouter les fichiers modifiés à l'étape 3 avec git add, sans relancer la sauvegarde (elle sera enregistrée automatiquement et son bloc disparaîtra)
