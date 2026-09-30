# Eevee Lyrics Bridge

Prototype expérimental pour EeveeSpotify standalone.

- remplace le rôle de `zxPluginsInject.dylib` tout en chargeant l’original renommé ;
- lit `MPNowPlayingInfoCenter` à l’intérieur du processus Spotify ;
- récupère les paroles synchronisées via LRCLIB ;
- expose l’état uniquement sur un socket TCP local ;
- remplace l’extension Widget Spotify par un widget LyricsDrive `.systemSmall`.

Le bundle Spotify original n’est pas stocké dans GitHub. Le script de packaging s’applique localement à l’IPA fourni par l’utilisateur.

## v0.4 diagnostic

Dans Spotify, toucher **LD · diagnostic** (en haut à droite).

1. Lancer une chanson et laisser jouer 15 secondes.
2. Ouvrir le diagnostic puis **Copier le diagnostic**. Le texte contient le titre/artiste, les positions et erreurs techniques, sans jeton Spotify ; vérifier le texte avant de le partager.
3. **Tester l’affichage · 30 secondes** injecte six phrases locales, sans requête LRCLIB, dans les mêmes chemins WidgetKit / ActivityKit. La musique n'est pas contrôlée par ce test. Refaire le test sur CarPlay à l'arrêt, puis iPhone verrouillé.
4. **Revenir à Spotify** rétablit le suivi réel. Le test reste actif jusqu'à ce bouton ou au redémarrage de Spotify.

Le rapport distingue demande de rechargement, requête reçue du widget, timeline fournie et envoi à ActivityKit. Aucun de ces signaux ne prouve que CarPlay a réellement rendu la dernière phrase : comparer avec l'écran.

Corrections : lecture TCP jusqu'au délimiteur (paquets fragmentés), délai/erreur JSON explicites, écoute limitée à 127.0.0.1, durée inconnue qui ne bloque plus la position du widget à zéro. Les erreurs LRCLIB et ActivityKit sont exposées. L'algorithme d'horloge v0.3 est conservé pour observer les valeurs brutes et les recalages avant une refonte.

Le workflow macOS compile le bridge et le widget, exécute des tests Swift du protocole (fragmentation, UTF-8, troncature, limite de taille) et livre les binaires avec SOURCE_COMMIT.txt. Les essais iPhone/CarPlay restent nécessaires.
