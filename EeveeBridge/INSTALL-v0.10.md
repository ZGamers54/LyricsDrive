# LyricsDrive v0.10 — correctif expérimental pour la v0.9

Cet ensemble est un patch compilé, pas une IPA à installer directement. Le bridge et l’extension doivent être remplacés ensemble : leur état ActivityKit partagé a changé.

Avec Python 3, depuis ce dossier :

```sh
python3 package_patch.py EeveeSpotify-LyricsDrive-v0.9-SelfTimed.ipa EeveeSpotify-LyricsDrive-v0.10.ipa
```

L’IPA originale reste intacte. Signer et installer le résultat avec le même outil que la v0.9 en conservant l’extension WidgetExtension.appex. iOS 26 minimum. Aucune IPA Spotify n’est publiée dans ce dépôt.

## Vérifier sur l’iPhone, sans aller à la voiture

Ouvrir Spotify une fois et commencer un morceau depuis le début. Attendre l’apparition des paroles, puis verrouiller l’iPhone pendant au moins trois minutes. Observer plusieurs changements de phrase après la première minute. Passer au morceau suivant depuis les commandes du verrouillage, puis tester pause/reprise et un déplacement dans le morceau. Après déverrouillage, le diagnostic doit montrer des relevés et des envois en arrière-plan ; ces compteurs prouvent seulement le travail du bridge, pas le rendu de l’écran.

Rejouer un morceau dont les paroles ont été chargées doit afficher « Cache local » dans le diagnostic sans requête LRCLIB. Lors d’un 503 sur un morceau non enregistré, le bridge affiche « Chargement des paroles… » et reprend avec un délai progressif respectant Retry-After ; les détails HTTP restent dans le diagnostic.

## Limites à vérifier

ActivityKit décide quand iOS rend les mises à jour. Une horloge TimelineView ne garantit pas des changements de texte à fréquence fixe lorsque le téléphone est verrouillé. Cette version envoie les phrases depuis le processus audio Spotify, conserve une seule activité entre les morceaux et limite chaque état à moins de 4 Ko. Si iOS suspend Spotify ou limite le rendu, aucune promesse de synchronisation continue ne peut être faite sur la seule compilation. Une première écoute sans cache nécessite encore que LRCLIB redevienne disponible.

La présentation v0.9 est conservée en attendant une photo de référence accessible. Le test CarPlay du Dashboard reste distinct de celui du verrouillage.
