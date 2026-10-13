# Fil

Fil est un client macOS de transferts distants, pensé pour être plus direct, calme et rapide que Cyberduck.

## Moment d'usage

Fait pour 3 h du matin : choisir une connexion, voir les fichiers, lancer un transfert, fermer la fenêtre. Chaque choix doit réduire l'attente et l'incertitude.

## Priorités produit

1. FTP et FTPS
2. SFTP
3. WebDAV
4. kDrive, d'abord via WebDAV puis via API si nécessaire
5. Proton Drive, via le CLI officiel comme intégration secondaire prioritaire

## Règles non négociables

- macOS natif, SwiftUI/AppKit, SwiftPM seul au démarrage.
- Le modèle ne dépend jamais de SwiftUI. Les effets réseau sont derrière des protocoles testables.
- Une seule source pour les jetons visuels : `Sources/Fil/Design/`.
- Une page par phase, pilotée par un modèle observable. Pas de navigation empilée pour les états d'un transfert.
- Un seul bouton plein principal par écran. Les actions secondaires sont des liens ou des contrôles discrets.
- Toute attente a une phrase. Toute condition bloquante a une raison lisible.
- Les secrets vont dans le Keychain, jamais dans les favoris ou les logs.
- Le cache est reconstructible et ne devient jamais la vérité.
- Le français est la langue de l'interface initiale. Les nombres, tailles et durées passent par `Format`.
- Aucun appel réseau de télémétrie.

## Structure

```text
Sources/CCurl/ pont C minimal vers la libcurl de macOS (FTP, FTPS)
Sources/Fil/
  Model/       valeurs pures : connexions, chemins, fichiers, phases, readiness
  Transfer/    abstractions d'effets : fournisseurs (FTP/, SFTP/, WebDAV/), file de transferts
  App/         état observable et composition de l'application
  Design/      Palette, TypeScale, Radius, composants
  Views/       une vue par phase et réglages
Tests/         tests du modèle, des règles, des fournisseurs simulés et d'intégration
docs/          décisions, reprise, plan protocole et guide testeurs
Support/       notes de distribution et informations macOS
Tools/         serveurs de test locaux, tests d'intégration, paquet .app
```

## Tenir les décisions

Toute décision qui change une API, une dépendance, une règle de sécurité ou la DA doit être ajoutée à `docs/DECISIONS.md` avec une date, un pourquoi et un lien vers le type concerné. Les travaux non terminés vont dans `docs/NEXT.md`.

## Construire

```sh
swift build
swift test
swift run Fil
Tools/integration-tests.sh   # vrais serveurs locaux SFTP, WebDAV, FTP, FTPS
Tools/bundle.sh              # .build/Fil.app signé ad hoc
```

Pour une future distribution, construire hors d'un dossier synchronisé, signer, puis recopier avec `ditto --noextattr --norsrc`.
