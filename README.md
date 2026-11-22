# CubeAR — plans de pièces avec LiDAR

Application iPhone native en SwiftUI, ARKit et RoomPlan. Elle scanne une pièce avec le LiDAR, génère un plan 2D, puis permet de corriger murs, portes, fenêtres et mobilier. Les plans sont organisés par lieux, sauvegardés localement et visualisables en 3D.

## Prérequis

- Windows 10 ou 11 avec VS Code et Git ;
- un iPhone compatible LiDAR (un iPhone 15 Pro Max convient) ;
- un câble USB pour la première connexion ;
- un Apple Account gratuit ;
- un compte GitHub.

L’application est compilée par GitHub Actions sur macOS puis installée sur l’iPhone depuis Windows avec AltServer. Aucun Mac ni abonnement Apple Developer ne sont nécessaires pour ce test personnel.

## 1. Préparer Windows

Suivre le guide officiel [AltStore Classic — Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).

1. Installer **iTunes pour Windows** et **iCloud pour Windows** directement depuis les liens Apple du guide AltStore. Ne pas prendre les versions du Microsoft Store : AltServer a besoin des composants Apple installés par les versions téléchargées directement.
2. Pendant l’installation d’iCloud, il est conseillé de désactiver les mises à jour automatiques pour éviter une incompatibilité temporaire avec AltServer.
3. Télécharger puis installer **AltServer pour Windows** depuis [altstore.io](https://altstore.io/).
4. Lancer AltServer en tant qu’administrateur. S’il demande un accès réseau, autoriser uniquement les **réseaux privés**.

Un avertissement Windows concernant `Bonjour/mdnsNSP.dll` peut apparaître après l’installation d’iCloud. Ne pas désactiver la protection LSA de Windows : fermer l’alerte ou cocher « Ne plus afficher ce message ». L’installation et le renouvellement en USB restent possibles.

## 2. Connecter l’iPhone à Windows

1. Brancher l’iPhone en USB et le déverrouiller.
2. Accepter « Faire confiance à cet ordinateur » sur l’iPhone.
3. Ouvrir iTunes, cliquer sur l’icône de l’iPhone, puis dans **Résumé** cocher « Synchroniser avec cet iPhone via Wi‑Fi » et cliquer sur **Appliquer**.
4. Le PC et l’iPhone doivent ensuite être sur le même Wi‑Fi privé. Le câble reste la solution la plus fiable si la connexion Wi‑Fi ne fonctionne pas.

## 3. Installer AltStore sur l’iPhone

1. Dans la zone de notification Windows, cliquer sur l’icône AltServer.
2. Choisir **Install AltStore**, puis choisir l’iPhone.
3. Saisir l’adresse e-mail et le mot de passe de son Apple Account directement dans AltServer. Ce compte peut être le compte personnel ou un compte dédié gratuit.
4. Sur l’iPhone, aller dans **Réglages → Général → VPN et gestion de l’appareil** et faire confiance au profil associé au compte Apple.
5. Sur iOS 16 ou version ultérieure, activer **Réglages → Confidentialité et sécurité → Mode développeur**, puis redémarrer l’iPhone lorsqu’il le demande.

## 4. Générer l’IPA avec GitHub Actions

1. Modifier le code dans VS Code.
2. Faire un commit et un push sur la branche `main`.
3. Ouvrir l’onglet **Actions** du dépôt GitHub puis attendre que le workflow **Build iOS** soit vert.
4. Dans le résumé du workflow réussi, télécharger l’artefact **CubeAR-unsigned-ipa**. Il contient `CubeAR-unsigned.ipa`.

Le workflow utilise un runner macOS pour générer une IPA non signée. AltServer la signe ensuite temporairement pour le téléphone avec le compte Apple gratuit.

Le build démarre sur les pushs, y compris ceux d’une branche ayant une pull request ouverte. Il n’est pas relancé une seconde fois par l’événement de pull request ; un nouveau push sur la même branche annule son build précédent encore en cours. Le build teste donc le commit de la branche, pas le résultat d’une fusion simulée avec `main`.

## 5. Installer ou mettre à jour CubeAR

1. Garder AltServer ouvert et l’iPhone connecté en USB ou en Wi‑Fi.
2. Maintenir la touche `Shift` puis cliquer sur l’icône AltServer.
3. Choisir **Sideload .ipa…**.
4. Sélectionner `CubeAR-unsigned.ipa` téléchargé depuis GitHub.
5. Attendre la notification de réussite, puis ouvrir CubeAR sur l’iPhone et autoriser la caméra.

Pour une mise à jour, ne pas supprimer CubeAR : installer simplement la nouvelle IPA par-dessus l’ancienne. Les données locales sont normalement conservées. Supprimer l’app peut supprimer les plans sauvegardés.

## Renouvellement gratuit

Avec un Apple Account gratuit, l’autorisation de développement expire après environ 7 jours. Ouvrir AltStore sur l’iPhone et utiliser **Refresh All** pendant qu’AltServer est accessible en USB ou sur le même Wi‑Fi. Si l’app a été installée directement par le menu « Sideload .ipa », il peut être nécessaire de sélectionner à nouveau l’IPA avec AltServer.

La limite habituelle est de trois applications sideloadées actives avec un compte Apple gratuit. Pour ce projet personnel, aucun paiement n’est nécessaire tant que l’on renouvelle l’application.

## Utiliser le scanner de plans

- Choisir le bouton scanner et marcher lentement le long des murs ; viser les portes et fenêtres.
- RoomPlan est une première détection : corriger les éléments mal reconnus avec la sélection, le changement de type, la suppression ou le bouton `+`.
- Les plans sont rangés dans **Mes lieux** (icône dossier) : un lieu peut contenir plusieurs plans/scans.
- Le bouton cube ouvre une représentation 3D.
- Pour tester une ouverture à la caméra : activer **Éditer**, sélectionner un mur puis choisir **Mesurer une ouverture avec la caméra**. Viser le mur, toucher deux coins diagonaux du cadre sur la même surface détectée, choisir porte/fenêtre/porte-fenêtre et placer approximativement l’ouverture sur le mur. Les rectangles verts sont des candidats visuels et ne sont pas automatiquement utilisés pour calculer les dimensions. Les indications d’orientation et dimensions sont expérimentales ; contrôler au mètre. La session caméra n’est pas encore relocalisée sur le plan : l’utilisateur doit viser le bon mur et choisir manuellement la position. L’ouverture ajoutée est actuellement un élément graphique distinct, sans découpe 3D ni association persistante au mur.
- Sur le plan 2D, glisser déplace la vue, pincer zoome, tourner deux doigts pivote la vue et un double toucher recentre. Toucher sélectionne un élément ; activer **Éditer**, puis maintenir et glisser permet de le déplacer. **Annuler** revient sur le dernier déplacement ; **Réinitialiser** restaure les positions au début de la session d’édition, après confirmation. Les suppressions, ajouts et rotations ne sont pas concernés. Le menu des calques permet de superposer numéros, longueurs, angles et indicateurs de murs parallèles. Les angles et parallélismes sont des estimations, pas des corrections géométriques.
- Le périmètre est exprimé en mètres et la surface en mètres carrés. La surface n’est estimée que si les murs forment un contour unique, fermé et non croisé (tolérance de raccord de 8 cm) ; elle n’est pas garantie pour un relevé architectural.
- Les dimensions affichées sont `L × P × H` : largeur, profondeur et hauteur, en mètres.

Les miroirs, grandes vitres, pièces sombres et couloirs étroits peuvent produire des murs ou ouvertures inexacts. Toujours vérifier les mesures si le plan doit servir à un usage architectural précis.

## Essais sans LiDAR

Depuis le plan, le bouton scanner propose deux méthodes : **Avec LiDAR** (RoomPlan) et **Sans LiDAR — contact**. Le scan LiDAR remplace le plan sélectionné après confirmation : créez d’abord un nouveau plan dans le dossier pour conserver l’ancien. Les anciens écrans expérimentaux ne sont plus accessibles, mais leur code est conservé pour ne pas perdre leurs fonctionnalités pendant la transition.

Le **Relevé par contact** mesure les murs dans l’ordre sans LiDAR. Choisir le sens de parcours vu du dessus, puis démarrer chaque capture avant de poser l’écran contre une partie accessible du mur. Après un délai minimal de 3 s, une fenêtre stable d’environ 1 s avec suivi ARKit normal déclenche une vibration ; après 10 s, une capture insuffisante échoue. À la fin, revenir au premier mur pour contrôler la boucle : cette dernière observation ne crée pas de mur supplémentaire. Si le contrôle est cohérent, une vue 3D et l’enregistrement d’un nouveau plan dans le lieu sélectionné sont disponibles. La hauteur des murs est renseignée manuellement et n’est pas mesurée par le relevé.

Avant de commencer, choisir **Une prise** ou **Deux points espacés** par mur. Dans le second mode, prendre deux mesures sur la même face, à au moins 30 cm l’une de l’autre ; le mur est ajouté seulement après validation des deux prises. Si le mur ne permet pas deux prises, **Passer la deuxième prise pour ce mur** permet d’utiliser la première seule ; les murs suivants restent en mode deux points. En cas d’écart trop important, la première prise reste dans le brouillon et la seconde peut être refaite. La direction est estimée à partir des deux positions, après vérification approximative des orientations (tolérance expérimentale de 15°) ; le résultat dépend toujours de la calibration et du suivi ARKit. Le contrôle du premier mur en fin de parcours utilise une seule prise.

Chaque mur enregistré est sauvegardé automatiquement comme brouillon local, y compris si la boucle n’est pas terminée. **Terminer le parcours** sauvegarde le brouillon ; le contrôle de la boucle est facultatif. Pour le retrouver : bouton scanner → Sans LiDAR — contact → **Relevés sauvegardés**.

Lorsque le suivi et la cartographie ARKit sont suffisants, l’application enregistre aussi une carte de l’environnement pour permettre la reprise après fermeture. Avant de quitter, observer le message de carte, explorer lentement la pièce si nécessaire, puis utiliser **Actualiser la carte pour reprendre plus tard**. Pour reprendre, revenir au même endroit et viser les surfaces déjà observées jusqu’au message de reconnaissance. Les nouvelles mesures sont bloquées pendant la relocalisation ; fermer le relevé permet de renoncer sans effacer le brouillon. Les anciens brouillons sans carte restent consultables uniquement. La relocalisation peut échouer si l’éclairage ou la pièce ont changé : elle ne garantit pas l’exactitude des mesures. Ne désinstallez pas l’app sans sauvegarde : les données sont locales.

Pendant la première mesure, une photo de repère facultative peut être prise téléphone en main (écran visible), puis consultée lors de la reprise ARKit. Elle est stockée localement avec le brouillon ; elle ne sert pas à calculer une position automatiquement. Dans la liste des relevés, **Consulter** montre le brouillon sans lancer la caméra ; **Reprendre avec ARKit** essaie de retrouver la carte. L’alignement manuel par coins ou marqueurs n’est pas encore implémenté.

Dans l’aperçu du relevé, les étiquettes M1, M2… identifient les murs et la flèche bleue indique approximativement la position et la direction de la caméra pendant un suivi normal. Une mesure qui semble redoubler le dernier mur ou dont le coin avec lui est indéterminé est refusée sans incrémenter le numéro. Le contrôle de boucle distingue l’écart du mur 1 de l’état global du contour : un mur 1 cohérent ne garantit pas un contour valide.

Pour fermer une pièce, mesurer chaque mur une fois, puis choisir **Fermer le contour : contrôler le mur 1** : cette dernière prise contrôle le premier mur et ne crée pas de mur supplémentaire. Si une nouvelle prise ressemble au mur 1, l’app demande si elle doit servir au contrôle ou être conservée comme nouveau mur. Dans les relevés existants, un dernier mur ressemblant au premier est signalé et peut être retiré après confirmation ; aucun mur n’est supprimé automatiquement.

Dans le relevé, le bouton vert **Vérifier le mur 1** lance ce contrôle ; les fonctions moins courantes sont dans **Options**. Le sens de parcours différent de celui choisi donne un avertissement, mais ne bloque plus un contour géométriquement cohérent dont le mur 1 correspond. Un trait orange en pointillés indique la direction approximative d’un mur dont les extrémités restent inconnues ; ce trait ne représente pas sa longueur réelle.

Cette unification est une étape intermédiaire : les plans existants sont conservés. Le nouveau modèle de logement et d’ouvertures est préparé mais pas encore relié à l’interface ni à la sauvegarde. Les pièces ne sont donc pas encore rattachables entre elles par une porte ; aucune transformation entre sessions AR n’est supposée.

Les paramètres expérimentaux sont dans `SurveySettings` : mouvement maximal 1,5 cm, rotation maximale environ 2°, intersections écartées si quasi parallèles ou à plus de 10 m, fermeture dite cohérente sous 10 cm et 5°. Le décalage caméra-écran est réglable avant le premier mur (1 cm par défaut, sans calibration certifiée). Ces seuils et la direction physique du décalage doivent être vérifiés sur appareil avec et sans coque : un suivi stable ou une boucle cohérente ne garantit pas une mesure exacte.

Sur Mac avec XcodeGen et Xcode, générer le projet avec `xcodegen generate`, puis exécuter les tests `CubeARTests` via Xcode ou `xcodebuild test` sur un simulateur iOS disponible. Les tests géométriques n’ont pas besoin de session AR active.
# Outils expérimentaux : reconnaissance par caméra

Dans l’éditeur de plan, touchez l’icône des outils puis « Reconnaissance d’objets ». Le premier essai utilise Vision pour proposer des descriptions de l’image en direct, sans LiDAR ni modification du plan. Ces descriptions ne localisent pas les objets et ne garantissent pas la reconnaissance des portes ou fenêtres.

Le bouton d’import permet aussi de tester un fichier `.mlmodel` de détection compatible avec les observations d’objets de Vision (`VNRecognizedObjectObservation`), ou un modèle de classification compatible Vision. Le fichier peut être envoyé sur l’iPhone avec l’app Fichiers ; l’import ne conserve le modèle que pour la durée de l’essai. Les cadres sont des estimations 2D, sans mesures ni ajout au plan. Tous les modèles Core ML ne produisent pas directement ce type de résultats : certains modèles nécessitent un décodage spécifique. Aucun modèle spécialisé portes/fenêtres n’est actuellement fourni ; il doit avoir été entraîné sur ces catégories et disposer d’une licence adaptée.
