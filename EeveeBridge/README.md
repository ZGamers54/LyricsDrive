# Eevee Lyrics Bridge

Prototype expérimental pour EeveeSpotify standalone.

- remplace le rôle de `zxPluginsInject.dylib` tout en chargeant l’original renommé ;
- lit `MPNowPlayingInfoCenter` à l’intérieur du processus Spotify ;
- récupère les paroles synchronisées via LRCLIB ;
- expose l’état uniquement sur un socket TCP local ;
- remplace l’extension Widget Spotify par un widget LyricsDrive `.systemSmall`.

Le bundle Spotify original n’est pas stocké dans GitHub. Le script de packaging s’applique localement à l’IPA fourni par l’utilisateur.
