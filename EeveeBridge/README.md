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

## v0.5 — horloge

Le rapport reçu sur la v0.4 montrait une position brute à 7,53 s, inchangée depuis 64,7 s. Les 109 lignes étaient reçues mais l'horloge se recalait continuellement en arrière avant la première ligne (12,46 s).

La nouvelle horloge utilise le temps monotone écoulé depuis son ancre. Une valeur brute identique ne déclenche plus de recalage, même après plusieurs relevés. Une nouvelle valeur, y compris zéro, est appliquée une seule fois. Une pause/reprise avec une valeur inchangée conserve la position locale.

Tests Swift : répétition exacte du rapport, retours/avances, retour à zéro, pause/reprise avec ancre figée, valeurs manquantes/invalides, durée inconnue/fin de morceau, nouveau morceau. Après installation, démarrer une chanson depuis le début pour disposer d'une ancre fraîche. Le diagnostic v0.5 et le test local restent disponibles.


## v0.6 CarPlay

Base v0.5 conservée, avec avance visuelle de 450 ms et présentation CarPlay dédiée pour le widget et la Live Activity.


## v0.10 — disponibilité et mises à jour en lecture verrouillée

Base exacte : commit v0.9 `3f2f580ba4fa3350c39cab76565daf48aacbfef3`. Le rendu visuel reste celui de la v0.9 en attendant une photo de référence accessible.

- Cache persistant des paroles, isolé par titre/artiste/album/durée, lisible après le premier déverrouillage. Les erreurs ne remplacent jamais les données enregistrées.
- Reprises sur réseau/408/429/5xx avec recul exponentiel plafonné à 60 s, jitter et respect de Retry-After. Les reprises sont annulées au changement de morceau. Un 503 reste visible dans le diagnostic technique, pas dans la carte des paroles.
- Une seule Live Activity conservée entre les morceaux. Le morceau courant est dans l’état dynamique ; aucune recréation en arrière-plan n’est nécessaire pour le passage à la chanson suivante.
- Envoi des changements de phrase et des recalages depuis le processus Spotify pendant sa lecture audio réelle, avec une tâche iOS courte pour terminer chaque envoi. Aucun son artificiel ni maintien forcé de l’application.
- Suppression de la promesse d’un planning de texte autonome dans TimelineView. Les états sont bornés à 3 500 octets attributs compris ; seules la phrase courante et la suivante sont envoyées.
- Ancre mise à jour même pour un déplacement dans la même phrase. Publication coalescée et ordonnée pour éviter qu’une ancienne chanson remplace la nouvelle.
- Diagnostic des relevés et envois en arrière-plan, sans assimilation à une preuve de rendu.

Le workflow `build-v06-carplay.yml` compile le correctif v0.10 et vérifie le cache, les réponses 503 successives, Retry-After, les déplacements, la limite ActivityKit, l’horloge existante et le protocole. Les anciens workflows de prototypes intégrés restent lançables manuellement ; ils dépendent de sources absentes de cette branche.

[Installation locale et essai verrouillé](INSTALL-v0.10.md). Le patch ne contient pas Spotify. Les premières écoutes sans cache dépendent encore de LRCLIB ; iOS reste maître du rendu verrouillé et CarPlay.
