# Monter une connexion dans le Finder — exploration

2026-10-16. Cette note dit ce qui est possible, ce que ça coûte, et ce qui a été vérifié sur macOS 27.0.1. La voie 1 est faite (voir `DECISIONS.md`, « Ouvrir dans le Finder ») ; les autres restent à l'état d'exploration.

## Ce que macOS sait déjà monter

`NetFS` (`NetFSMountURLAsync`) monte une URL comme le fait « Se connecter au serveur » du Finder. Plugins présents : `ftp`, `http` (WebDAV), `nfs`, `smb`. Pas de `ftps`, pas de `sftp`.

Vérifié avec `Tools/test-servers.sh` et un petit binaire qui appelle `NetFSMountURLSync` (identifiant et mot de passe passés en arguments, jamais dans l'URL) :

| Protocole | Résultat |
|---|---|
| WebDAV (`http://…/dav/`) | Monté en **lecture-écriture**. Lire, créer un fichier : OK. Le serveur reçoit aussi `._depuis-finder.txt` (fichier AppleDouble). |
| FTP (`ftp://…`) | Monté en **lecture seule** (`Read-only file system`). |
| FTPS, SFTP | Aucun plugin. Impossible sans autre mécanisme. |

Pour Fil, cela couvre WebDAV et kDrive (qui passe d'abord par WebDAV), soit les priorités 3 et 4. Ça ne couvre ni FTP en écriture, ni FTPS, ni SFTP, soit les priorités 1 et 2.

## Les quatre voies

### 1. NetFS pour WebDAV — petit, sans extension

Une action « Ouvrir dans le Finder » sur une connexion WebDAV : Fil lit le mot de passe dans le Keychain, appelle `NetFSMountURLAsync` avec `kNetFSMountAtMountDirKey` absent (montage sous `/Volumes`), puis `NSWorkspace.shared.open(mountpoint)`.

- Coût : une fonction derrière un protocole (`VolumeMounter`), testable avec un double. SwiftPM seul, signature ad hoc suffisante.
- Limites :
  - Le Finder écrit des `._*` et `.DS_Store` sur le serveur. Pour un site déployé, c'est sale. On peut prévenir dans une phrase, pas empêcher.
  - Un serveur qui tombe gèle le Finder (fenêtre « connexion interrompue »). Fil ne contrôle rien après le montage.
  - Le volume vit sans Fil : la règle « toute attente a une phrase » ne s'applique plus une fois dans le Finder.
- FTP en lecture seule est possible par le même appel, mais un volume FTP sans écriture ni FTPS risque de semer la confusion. À ne pas proposer.

### 2. Pont WebDAV local — tous les protocoles, sans extension

Fil sert un WebDAV sur `127.0.0.1` adossé à `RemoteFileProvider`, puis le monte avec NetFS. Le Finder verrait SFTP, FTP et FTPS en écriture.

- Coût élevé : écrire un serveur WebDAV que `webdavfs` accepte. Il faut `PROPFIND`, `GET` avec plages, `PUT`, `MOVE`, `DELETE`, `MKCOL`, **et `LOCK`/`UNLOCK`** : sans classe 2, `webdavfs` monte en lecture seule (à confirmer sur le pont lui-même).
- Fil doit rester ouvert tant que le volume est monté. Ça contredit « fermer la fenêtre », ou impose un mode barre des menus.
- Les performances de `webdavfs` sont médiocres sur les gros dossiers et les gros fichiers.

### 3. File Provider — la voie d'Apple, celle de Mountain Duck, Dropbox et iCloud

Une extension `NSFileProviderReplicatedExtension` par application, un `NSFileProviderDomain` par connexion. La connexion apparaît dans la barre latérale du Finder, sous « Emplacements ». Les fichiers sont téléchargés à l'ouverture, envoyés à l'enregistrement, et peuvent être évincés.

- Couvre tous les protocoles : l'extension appelle les mêmes `RemoteFileProvider` que l'application. Le modèle (`Model/`) et les fournisseurs (`Transfer/FTP`, `SFTP/`, `WebDAV/`) se partagent sans changement d'API.
- Le Finder reste réactif hors ligne : le système affiche ses propres états (nuage, progression) au lieu de geler.
- Coût :
  - **Cible d'extension `.appex`.** SwiftPM ne produit pas de bundle d'extension. Deux options : un projet Xcode (contredit « SwiftPM seul au démarrage »), ou un exécutable SwiftPM lié avec `-e _NSExtensionMain`, empaqueté par `Tools/bundle.sh` dans `Fil.app/Contents/PlugIns/`. La seconde garde SwiftPM, mais reste à prouver.
  - **Signature réelle.** L'extension est sandboxée et partage un App Group et un groupe Keychain avec l'application. La signature ad hoc ne suffit pas pour ces droits. Une identité « Apple Development » est présente sur cette machine (équipe `8K4K3D28R7`), ce qui suffit pour un prototype local. La distribution aux testeurs demandera Developer ID et notarisation.
  - **Identité des éléments.** FTP et WebDAV n'ont pas d'identifiant stable : le chemin sert d'identifiant, et un renommage fait du même fichier un nouvel élément. C'est acceptable si l'extension traite le renommage comme suppression puis création, et si le serveur reste la vérité (règle du cache).
  - **Changements distants.** Aucun de ces protocoles ne pousse de notification. Il faut relister à la demande (`enumerateChanges` sur le dossier ouvert) et accepter un retard.
  - **Secrets.** L'extension lit le Keychain via un groupe d'accès partagé. Ça change la règle de sécurité : à inscrire dans `DECISIONS.md`.

### 4. FUSE et FSKit — écartés

- macFUSE (installé sur cette machine, 5.1.2) ou FUSE-T : dépendance tierce que les testeurs n'auront pas, avec extension système ou serveur NFS local. Contraire à « macOS natif ».
- FSKit (présent dans `/System/Library/Frameworks`) : extension aussi, pensée d'abord pour les systèmes de fichiers sur disque. Rien ne laisse penser aujourd'hui qu'il simplifie un système de fichiers réseau par rapport à File Provider. À revérifier si Apple l'étend.

## Recommandation

1. **Maintenant, si l'envie est là :** « Ouvrir dans le Finder » pour WebDAV et kDrive via NetFS (voie 1). Petit, natif, vérifié ici. Un lien discret dans le navigateur, pas un bouton plein, avec un avertissement d'une phrase sur les `._*`.
2. **Pour FTP, FTPS et SFTP :** un prototype File Provider (voie 3), en commençant par un domaine SFTP en lecture seule. Avant de commencer, il faut trancher deux points dans `DECISIONS.md` : l'empaquetage de l'extension (SwiftPM + `bundle.sh`, ou projet Xcode) et la signature (identité Apple Development, App Group, groupe Keychain).
3. Ne pas écrire de pont WebDAV local (voie 2) : il coûte autant que File Provider et donne un résultat moins bon.

## Questions ouvertes

- Confirmer que `-e _NSExtensionMain` et un `Info.plist` `NSExtension` assemblés à la main suffisent pour que `fileproviderd` charge l'extension (`pluginkit -m -p com.apple.fileprovider-nonui`).
- Vérifier que le glisser vers le Finder déjà en place (`DragOut.swift`) et un domaine File Provider ne se gênent pas : deux chemins de téléchargement pour le même fichier.
- Décider si un volume monté doit se démonter quand on oublie la connexion dans Fil.
