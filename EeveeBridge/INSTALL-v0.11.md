# Installation et essai LyricsDrive v0.11

Le correctif est compilé pour iOS 26 et s’applique à l’IPA EeveeSpotify/LyricsDrive v0.9 de l’utilisateur.
Il remplace uniquement le bridge LyricsDrive et WidgetExtension.appex, et met à jour les métadonnées nécessaires.
Le binaire Spotify, l’injecteur d’origine et les autres fichiers Frameworks sont conservés.

## Installation

1. Installer l’IPA v0.11 fournie dans SideStore avec la même méthode que la v0.9.
2. Conserver WidgetExtension.appex lors de la signature et autoriser les Activités en direct pour Spotify.
3. Ouvrir Spotify au premier plan et démarrer un morceau depuis le début pour obtenir une ancre fraîche.
4. Dans **LD · diagnostic**, conserver d’abord **Décalage = 0 ms**.

SideStore intégré à LiveContainer peut gérer une app installée séparément.
Si Spotify est lui-même un invité LiveContainer, ses extensions ne sont pas enregistrées dans SpringBoard :
ce fonctionnement doit être distingué d’une installation indépendante. La signature de l’IPA assemblée
sera refaite par SideStore ; le profil et les entitlements de l’app installée ne sont pas observables depuis cette archive.

## Essai sans voiture

1. Vérifier pendant 20 secondes que la phrase suit le morceau au premier plan.
2. Verrouiller l’iPhone pendant deux minutes en laissant la musique jouer.
3. Observer si la phrase et la barre continuent ; noter l’heure ou la position musicale du gel éventuel.
4. Déverrouiller, ouvrir **LD · diagnostic**, puis **Copier le diagnostic**.
5. Faire ensuite un déplacement dans le morceau, une pause de cinq secondes et une reprise.

Le rapport conserve le dernier échantillon reçu en arrière-plan même après le déverrouillage.
Il comprend les clés/vitesses brutes, la position retenue, les échéances de phrases, le retard maximal
du minuteur, les envois ActivityKit terminés et les tâches iOS courtes expirées ou refusées.

Si le texte reste en retard d’une quantité stable, essayer un décalage positif, par exemple **+200 ms**.
Un décalage négatif retarde les paroles. Le réglage va de −2000 à +2000 ms par pas de 100 ms et persiste
entre les lancements. Il ne corrige pas un arrêt des mises à jour.

## Limites

Un compteur d’envois terminés ne prouve pas le rendu par iOS. La lecture audio réelle peut permettre
au processus Spotify de travailler en arrière-plan ; elle ne garantit pas une cadence de rendu ActivityKit.
Le widget classique et la Live Activity ont des mécanismes différents. Aucune API publique n’offre
un accusé de rendu du texte ou un compteur de budget local utilisable ici.

Le détail HTTP reste uniquement dans le diagnostic. En cas de recherche/indisponibilité, la carte affiche **♪**.
Le cache positif et les reprises de la v0.10 sont conservés ; le circuit breaker, les caches avec expiration
et les recherches alternatives appartiennent à l’étape réseau suivante.
