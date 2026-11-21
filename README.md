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
- Les dimensions affichées sont `L × P × H` : largeur, profondeur et hauteur, en mètres.

Les miroirs, grandes vitres, pièces sombres et couloirs étroits peuvent produire des murs ou ouvertures inexacts. Toujours vérifier les mesures si le plan doit servir à un usage architectural précis.

## Essais sans LiDAR

L’onglet **Sans LiDAR** propose trois prototypes séparés : affichage des contours en direct, placement manuel de repères AR, puis création d’un contour de pièce en plaçant au moins trois coins au sol dans l’ordre. La création remplace le plan sélectionné après confirmation ; créez un nouveau plan au préalable pour conserver l’ancien. Les repères sont temporaires et les mesures restent approximatives. Ces prototypes ne détectent pas encore automatiquement les murs, portes ou fenêtres : vérifiez le résultat au mètre.
