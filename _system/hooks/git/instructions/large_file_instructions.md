Commit refusé : fichier volumineux.

Pour chaque fichier, suivre ces étapes :

1) Évaluer la recommandation à faire :
    - Laisser le fichier en place et le conserver dans git : s'il est nécessaire à cet emplacement pour qu'un système fonctionne (ex. une image chargée par une application, un modèle utilisé par un skill)
    - Sinon, le ranger dans le dossier data/ (non suivi par git) à la racine du dépôt
    - Dans tous les cas, choisir le dossier de data/ où il pourrait aller ([DOSSIER]) : suivre l'organisation déjà en place dans data/ (dossier existant pertinent, ou nouveau dossier cohérent avec les existants) ; si data/ ne contient aucun dossier, proposer par défaut `data/<Catégorie>/<année>/` (ex. data/Factures/2026/)

2) Afficher exactement le message ci-dessous, puis attendre la réponse de l'utilisateur :
    ```
    **[NOM DU FICHIER]** est un fichier volumineux ([TAILLE] Mo).
    
    3 possibilités :

    1. **Je le range dans `[DOSSIER]`** et mets à jour les liens qui y renvoient. Ce fichier reste alors accessible sur cet ordinateur mais n'est plus sauvegardé.
    2. **Je le laisse à sa place actuelle**. Il sera synchronisé, mais il alourdit la sauvegarde.
    3. **Tu le déplaces toi-même à un autre endroit** (Google Drive, Dropbox...) : il y sera sauvegardé, mais il sort de ton espace de travail.
  
    Recommandation : **[Numéro possibilité]** ([Raison courte sans jargon])

    Que préfères-tu ?
    ```

    Règles :
    - Si [DOSSIER] n'existe pas encore, ajouter « (nouveau dossier) » après `[DOSSIER]`
    - Ne jamais ajouter de jargon technique (commit, hook, .gitattributes) → garder le vocabulaire du message

3) Attendre le choix de l'utilisateur, puis l'appliquer :
    - Choix 1 : déplacer le fichier dans [DOSSIER], ou dans le dossier indiqué par l'utilisateur (toujours sous le dossier data/ à la racine du dépôt), sans le renommer (ajouter -2, -3... avant l'extension si le nom existe déjà), puis mettre à jour tous les liens du dépôt qui renvoient vers ce fichier (rechercher son nom dans les fichiers texte du dépôt) pour qu'ils pointent vers son nouvel emplacement.
      Puis exécuter la commande de retrait indiquée pour ce fichier dans le bloc ci-dessus
    - Choix 2 : ajouter au .gitattributes la ligne de laissez-passer indiquée pour ce fichier dans le bloc ci-dessus
    - Choix 3 : attendre que l'utilisateur confirme avoir déplacé le fichier, vérifier qu'il n'est plus à son emplacement (sinon le lui signaler et attendre), puis exécuter la commande du choix 1, à recopier telle quelle sans la modifier

4) Une fois tous les fichiers traités :
    - Si le refus est apparu pendant une sauvegarde ou un commit en cours : relancer cette sauvegarde ou ce commit, en y ajoutant les fichiers modifiés à l'étape 3 et en retirant les fichiers déplacés (choix 1 ou 3)
    - Si le refus a été signalé au démarrage de la session (bloc [save] de session_error.log) : ajouter les fichiers modifiés à l'étape 3 avec git add, sans relancer la sauvegarde (elle sera enregistrée automatiquement et son bloc disparaîtra)
