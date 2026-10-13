# Travaux non terminés

Ce qui manque, par ordre d'intérêt pour le moment d'usage (3 h du matin : choisir, voir, lancer, fermer).

## Transferts

- **Reprise d'un transfert interrompu.** Aujourd'hui, un échec repart de zéro (« Réessayer »). À faire : `REST` en FTP (`CURLOPT_RESUME_FROM_LARGE`), décalage d'ouverture en SFTP, `Range` en WebDAV, en gardant le fichier `.filpart`.
- **File persistante.** La file vit en mémoire : quitter Fil la vide. La garder sur disque (sans secret) pour reprendre au lancement.
- **Glisser depuis Fil vers le Finder** (`NSFilePromiseProvider`). Aujourd'hui : bouton « Télécharger », double-clic, menu contextuel ou ⌘D.
- **Dossiers liés.** Un lien symbolique vers un dossier n'est pas suivi pendant le téléchargement d'un dossier (protection contre les boucles). Proposer de le suivre avec une limite de profondeur.
- **Renommer et déplacer** : `RNFR`/`RNTO`, `SSH_FXP_RENAME`, `MOVE` WebDAV.

## Sécurité

- **Première connexion SFTP** : afficher l'empreinte et demander confirmation au lieu de l'accepter en silence (`accept-new`).
- **Certificat auto-signé** (NAS en FTPS ou WebDAV) : épingler une empreinte après confirmation explicite, par connexion. Aujourd'hui le certificat est refusé avec une raison lisible.
- **WebDAV non chiffré** sur réseau local : décision à prendre. Aujourd'hui HTTPS seulement.
- **Sandbox** : `/usr/bin/ssh` n'est pas utilisable dans la sandbox App Store. À étudier seulement si une distribution App Store est envisagée.

## Protocoles

- **Proton Drive** via le CLI officiel : vérifier sa disponibilité, ses commandes, sa sortie machine et son authentification, puis écrire l'adaptateur de processus.
- **kDrive** : valider en conditions réelles (mot de passe d'application, limites de taille, débit). Passer à l'API seulement pour une fonction absente ou un écart de performance mesuré.
- **FTP actif** (`PORT`) : non proposé, seul le passif est utilisé. Ajouter une option si un serveur l'exige (`CURLOPT_FTPPORT`).
- **Clé SSH par connexion** : aujourd'hui les clés viennent de l'agent et de `~/.ssh/config`. Un champ « clé » éviterait de passer par la configuration.

## Tests

- **Mot de passe SSH en test automatique** : un sshd non root ne sait pas vérifier un mot de passe. Le chemin `SSH_ASKPASS` → Keychain a été vérifié de bout en bout avec une clé protégée par phrase de passe, mais pas dans `swift test`.
- **Tests d'interface** : aucun test automatisé des vues. Les modèles observables (`AppModel`, `BrowserModel`, `TransferQueue`) sont testés.

## Application

- **Préférences séparées** : `swift run Fil` lit le domaine `Fil`, `Fil.app` lit `com.fil.app`. Les favoris ne sont donc pas partagés entre les deux. À unifier quand l'identifiant définitif sera choisi.
- Identifiant de bundle définitif, icône, signature Developer ID, notarisation (voir `Support/DISTRIBUTION.md`).
- Passe VoiceOver complète ; libellés d'accessibilité des actions du plateau déjà posés.
- Interface en anglais, après stabilisation des phrases françaises.
