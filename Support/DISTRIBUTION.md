# Notes de distribution

Rien n'est encore distribué. Ces notes fixent la marche à suivre le moment venu.

## Construire et notariser

Une fois, avec un compte développeur Apple payant :

1. Créer (ou installer) une identité **Developer ID Application** dans le trousseau. `security find-identity -v -p codesigning` doit la lister ; une identité « Apple Development » ne se notarise pas.
2. Enregistrer les identifiants de notarisation dans le trousseau (mot de passe d'application d'Apple ID, jamais dans le dépôt) :

   ```sh
   xcrun notarytool store-credentials fil-notary --apple-id <identifiant Apple> --team-id <ABCDE12345>
   ```

Puis, à chaque version :

```sh
FIL_SIGN_IDENTITY="Developer ID Application: Nom (ABCDE12345)" FIL_NOTARY_PROFILE=fil-notary Tools/release.sh
```

[`Tools/release.sh`](../Tools/release.sh) construit hors d'un dossier synchronisé (`~/Builds`, ou `FIL_RELEASE_DIR`), signe avec le runtime renforcé, soumet à Apple et attend, agrafe le ticket, contrôle avec `spctl`, puis écrit `Fil-<version>.zip`. Pour installer sur ce Mac : `ditto --noextattr --norsrc ~/Builds/Fil.app /Applications/Fil.app` (fermer Fil avant).

Le script n'a pas encore été exécuté de bout en bout.

## Avant la première distribution

- Choisir l'identifiant de bundle définitif (provisoire : `com.fil.app` dans `Support/Info.plist`) et le service Keychain associé (`com.fil.connections`). Changer l'un ou l'autre fait perdre l'accès aux favoris ou aux mots de passe enregistrés : prévoir une migration.
- Première installation signée Developer ID : les mots de passe du Keychain enregistrés par une version signée ad hoc peuvent demander une autorisation une fois (la signature qui les a créés a changé). À vérifier, puis à écrire ici.
- Le runtime renforcé n'empêche ni de lancer `/usr/bin/ssh` ni de charger la libcurl système. La sandbox, elle, les empêche : pas de distribution App Store sans revoir SFTP.
- Aucune télémétrie, aucune vérification de mise à jour réseau sans décision explicite.

## Dépendances système

- `libcurl` (FTP, FTPS) : bibliothèque de macOS, liée dynamiquement, non embarquée.
- `/usr/bin/ssh` (SFTP) : OpenSSH de macOS, appelé comme processus.
- Aucune bibliothèque tierce dans l'application.
