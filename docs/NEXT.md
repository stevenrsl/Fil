# Travaux non terminés

Ce qui manque, par ordre d'intérêt pour le moment d'usage (3 h du matin : choisir, voir, lancer, fermer).

## Transferts

- **Reprise entre deux sessions.** « Réessayer » reprend, mais seulement tant que Fil est ouvert : la file et son registre vivent en mémoire, et les partiels locaux sont effacés à la fermeture. Reprendre au lancement demanderait un témoin fiable du contenu (empreinte ou ETag), faute de quoi on risque de compléter un fichier qui a changé.
- **Reprise d'un envoi WebDAV.** Un `PUT` repart du début ; seuls les téléchargements reprennent (`Range`). À étudier : les extensions de téléversement par morceaux de Nextcloud et d'Infomaniak.
- **Partiels distants après fermeture de Fil.** Un envoi en échec laisse `nom.filpart` sur le serveur ; « Effacer les terminés » le supprime, mais pas la fermeture de l'application, qui ne peut pas compter sur le réseau.
- **Détection d'un fichier distant réécrit à la même taille** entre deux essais d'un téléchargement repris : aujourd'hui seule la taille est comparée.
- **Glisser depuis Fil vers le Finder** (`NSFilePromiseProvider`). Aujourd'hui : bouton « Télécharger », double-clic, menu contextuel ou ⌘D.
- **Dossiers liés.** Un lien symbolique vers un dossier n'est pas suivi pendant le téléchargement d'un dossier (protection contre les boucles). Proposer de le suivre avec une limite de profondeur.
- **Renommer et déplacer dans l'interface** : les fournisseurs savent déjà renommer (`move`), il manque le geste (touche Entrée sur un nom, menu contextuel).

## Sécurité

- **Première connexion SFTP** : afficher l'empreinte et demander confirmation au lieu de l'accepter en silence (`accept-new`).
- **Certificat auto-signé** (NAS en FTPS ou WebDAV) : épingler une empreinte après confirmation explicite, par connexion. Aujourd'hui le certificat est refusé avec une raison lisible, et la proposition FTPS reste muette si le certificat du serveur n'est pas reconnu.
- **FTPS implicite (port 990)** : la sonde de proposition ne teste que FTPS explicite.
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
- **Mode sombre de la bannière FTPS** : rendu clair vérifié hors écran, rendu sombre non vérifié (le moteur de rendu hors écran n'a pas résolu les couleurs adaptatives).
- **Proposition FTPS sur un vrai hébergeur** : validée contre un serveur local avec certificat de test, pas encore contre un serveur public (OVH, etc.).

## Application

- **Préférences séparées** : `swift run Fil` lit le domaine `Fil`, `Fil.app` lit `com.fil.app`. Les favoris ne sont donc pas partagés entre les deux. À unifier quand l'identifiant définitif sera choisi.
- Identifiant de bundle définitif, icône, signature Developer ID, notarisation (voir `Support/DISTRIBUTION.md`).
- Passe VoiceOver complète ; libellés d'accessibilité des actions du plateau déjà posés.
- Interface en anglais, après stabilisation des phrases françaises.
