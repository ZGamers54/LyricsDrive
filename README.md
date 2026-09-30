# LyricsDrive v0.3

LyricsDrive est un prototype iOS 26 en SwiftUI qui affiche des paroles Spotify synchronisées dans des surfaces compatibles CarPlay.

## Architecture

- **Spotify OAuth 2.0 Authorization Code + PKCE** — aucun client secret embarqué dans l’app.
- **Spotify Web API** — lecture du morceau en cours, de la position, de la durée et de l’état lecture/pause.
- **LRCLIB** — récupération des paroles LRC synchronisées.
- **App Group** — partage de l’état et de la timeline entre l’app et l’extension WidgetKit.
- **WidgetKit `systemSmall`** — widget iPhone compatible avec l’écran Widgets de CarPlay à partir d’iOS 26.
- **ActivityKit** — Live Activity avec prise en charge de la famille `.small` afin d’obtenir un rendu CarPlay dédié.

## Identifiants

- App : `com.zgamers54.LyricsDrive`
- Extension : `com.zgamers54.LyricsDrive.Widget`
- App Group : `group.com.zgamers54.LyricsDrive`
- Redirect Spotify : `lyricsdrive://callback`

Le redirect URI doit être ajouté exactement dans le Spotify Developer Dashboard. Pour une app iOS, Spotify recommande Authorization Code + PKCE et autorise un schéma d’URL personnalisé propre à l’application.

## Fonctionnement

1. L’utilisateur saisit son Spotify Client ID et autorise LyricsDrive.
2. LyricsDrive interroge périodiquement le morceau actuellement lu.
3. Au changement de morceau, l’app recherche les paroles synchronisées dans LRCLIB.
4. La timeline complète des paroles est écrite dans l’App Group.
5. Le widget prépare les futures lignes à afficher dans sa timeline.
6. La Live Activity est mise à jour lors des changements de ligne, lecture/pause et par paliers de progression afin d’éviter des mises à jour excessives.
7. Si Spotify est arrêté, l’état partagé et la Live Activity sont nettoyés.

## Limite importante

WidgetKit décide du moment exact auquel une entrée de timeline est rendue. La timeline pré-calculée améliore la continuité lorsque l’app est suspendue, mais ce mécanisme n’est pas un moteur de karaoké garanti à la milliseconde. De plus, si iOS suspend LyricsDrive puis que Spotify passe au titre suivant, la détection du nouveau titre peut attendre le prochain réveil de l’app.

## Build GitHub Actions

Le workflow `.github/workflows/build-ios.yml` :

1. s’exécute sur `macos-26` ;
2. sélectionne le dernier Xcode stable ;
3. installe XcodeGen ;
4. valide les plist/entitlements et parse les sources Swift ;
5. génère `LyricsDrive.xcodeproj` ;
6. compile l’app et `LyricsDriveWidgetExtension` pour `iphoneos` sans signature ;
7. vérifie que l’extension `.appex` est embarquée ;
8. crée `LyricsDrive-unsigned.ipa` ;
9. publie l’IPA comme artifact GitHub Actions.

L’IPA non signée doit ensuite être signée par l’outil de sideloading utilisé. Le signataire doit conserver l’extension WidgetKit et traiter correctement l’App Group.

## Configuration Spotify

Dans le Spotify Developer Dashboard :

- ajoute `lyricsdrive://callback` dans **Redirect URIs** ;
- ajoute `com.zgamers54.LyricsDrive` comme Bundle ID iOS ;
- copie le **Client ID** dans LyricsDrive ;
- aucun Client Secret n’est nécessaire dans l’app.

Scopes utilisés :

- `user-read-currently-playing`
- `user-read-playback-state`

## Références officielles

- Apple CarPlay : https://developer.apple.com/carplay/
- Apple WidgetKit / CarPlay : https://developer.apple.com/documentation/widgetkit/adding-standby-and-carplay-support-to-your-widget
- Apple Live Activities : https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Spotify PKCE : https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- Spotify iOS app configuration : https://developer.spotify.com/documentation/web-api/concepts/apps
