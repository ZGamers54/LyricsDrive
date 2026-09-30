# Étape 2 — synchronisation et exécution verrouillée

## Modifications certaines dans le code

- PlaybackClock conserve une position/ancre monotone et une vitesse numérique. Une vitesse absente ou
  invalide conserve la dernière valeur connue. Une vitesse explicite à zéro met en pause. Sans vitesse
  connue au démarrage, aucune lecture n’est inventée.
- Une nouvelle position brute recale l’horloge une seule fois ; une ancre répétée continue d’être extrapolée.
  Pause/reprise et changement de vitesse conservent la position courante. Un déplacement peut être
  détecté seulement si les métadonnées le rendent observable.
- LyricsSchedule utilise une recherche binaire commune au bridge et à l’extension. Un seul
  DispatchSourceTimer est armé pour la prochaine frontière de phrase sur stateQueue. Le délai vaut
  (horodatage LRC − décalage − position) / vitesse. Les échéances tardives retrouvent directement
  la phrase actuelle au lieu de rejouer des ticks ou des phrases dépassées.
- Le polling public Now Playing reste une détection de secours toutes les 500 ms ; au maximum une lecture
  du main thread est en attente. Une phrase inchangée ne crée pas une Task ActivityKit à chaque poll.
- Un changement de phrase, une pause/vitesse, une piste ou un seek significatif publie un nouvel état.
  Les événements de cycle de vie peuvent aussi demander un rafraîchissement limité à un toutes les deux secondes.
- Observateurs publics : premier/arrière-plan, protection des données, changement d’heure,
  connexion/activation/déconnexion de scène UIKit, interruption audio, changement de route et
  réinitialisation des services audio. Ils provoquent une lecture immédiate et une relecture 350 ms plus tard.
  Aucun sélecteur Spotify n’est supposé ; aucune commande audio ni modification de la session Spotify n’est émise.
  Les scènes ne constituent pas une preuve de présence de CarPlay ; les changements de route ne détectent
  pas nécessairement toutes les transitions CarPlay.
- Le décalage persistant est réglable dans LD · diagnostic, par pas de 100 ms entre ±2000 ms.
  Valeur initiale 0 ms : aucune compensation arbitraire de latence iOS.
- La barre native ProgressView(timerInterval:) tient compte de la vitesse ; le texte change par envoi ActivityKit.
  Un minuteur de SwiftUI ne sert pas à promettre une progression autonome des paroles verrouillées.
- Le dernier échantillon d’arrière-plan et ses clés sont conservés. Le journal os_log/Logger
  com.lyricsdrive.bridge contient des temps, vitesses et événements, sans titres ni paroles.

## Hypothèses à distinguer

Le gel à dix secondes peut provenir d’une interruption du suivi, d’une vitesse absente traitée comme pause
dans les versions précédentes, ou du rendu système alors que l’app continue de soumettre des états.
La durée seule ne permet pas de trancher et ne correspond pas à une limite universelle documentée.

## Exécution et ActivityKit

Une mise à jour locale nécessite une occasion d’exécution dans le processus hôte. Le mode background audio
permet la lecture audio réelle, sans garantir le maintien d’une app après pause, interruption, arrêt forcé
ou hébergement en tant qu’invité. La tâche UIKit courte ne protège que l’envoi en cours et est terminée ensuite.
Elle ne constitue pas un maintien en vie ni une solution au gel du renderer.

Apple documente explicitement un budget pour les notifications push ActivityKit. Ce budget et la clé
NSSupportsLiveActivitiesFrequentUpdates ne doivent pas être transformés en quota chiffré de mises à jour
locales. Ici pushType est nil : il n’y a ni enregistrement de token ActivityKit ni serveur APNs.
Un entitlement présent dans une archive ne prouve pas une autorisation APNs après re-signature.
APNs exigerait un profil valide et un fournisseur compatible avec le bundle installé ; cette installation
n’a pas été vérifiée, et APNs n’est pas une solution mise en œuvre.

## Mesures et vérification physique

- **Correction dernière ancre (seek compris)** : écart entre nouvelle position brute et prédiction.
  Un seek volontaire peut produire un grand écart ; une ancre figée n’est pas une mesure du retard audio.
- **Retard maximal du minuteur** : retard d’exécution de stateQueue par rapport à l’échéance monotone.
- **Plus grand intervalle entre relevés** : espacement monotone des lectures Now Playing, conservé après le retour.
- **Envois terminés / durée Activity.update / tâches courtes** : activité du chemin de soumission, jamais un ACK de rendu.
- Comparer ces valeurs avec la phrase réellement visible et le lecteur après deux puis dix minutes verrouillées.
  Refaire pause/reprise, seek, changement de piste et une interruption audio.

Un Mac avec l’iPhone branché peut examiner Console et filtrer com.lyricsdrive.bridge et liveactivitiesd.
Des rejets/throttlings observés dans les logs système étayent un diagnostic ; l’absence de message ne garantit
pas le rendu. Time Profiler et Energy Log peuvent mesurer le coût réel. Il n’existe pas encore de mesure
énergétique sur cet iPhone ; seul le nombre de polls théorique passe de quatre à deux par seconde.

## Sources primaires

- https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions
- https://developer.apple.com/documentation/uikit/uiscene
- https://github.com/LiveContainer/LiveContainer/blob/main/README.md

Les tests automatiques couvrent les anciennes ancres figées, les vitesses absentes/invalides, 0.5x/1.5x,
pause/reprise, déplacements, longues interruptions d’exécution, frontières exactes et en double,
offsets positifs/négatifs et déduplication des états. Ils ne simulent pas le rendu verrouillé d’iOS.
