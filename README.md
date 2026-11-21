# CubeAR

Application iPhone native (SwiftUI + ARKit) : toucher un sol ou un mur pour y poser un cube, le sélectionner, le faire pivoter, le supprimer et sauvegarder la carte AR avec ses positions.

## Développer depuis Windows

VS Code convient pour éditer le Swift et Git. Installe l’extension **Swift** pour la coloration et l’autocomplétion de base. ARKit, le simulateur iOS et l’analyse complète de Swift nécessitent toutefois macOS + Xcode : ils ne fonctionnent pas sur Windows.

Le projet est décrit dans `project.yml`. Sur un Mac, installer Xcode puis XcodeGen (`brew install xcodegen`), exécuter `xcodegen generate`, ouvrir `CubeAR.xcodeproj` dans Xcode, choisir un iPhone réel et définir ton `DEVELOPMENT_TEAM` ainsi qu’un identifiant unique à la place de `com.votreidentifiant.CubeAR`.

## Sauvegarde AR

Le bouton **Sauvegarder** enregistre localement une `ARWorldMap` : elle contient les ancrages des cubes et les repères visuels du lieu. **Restaurer** doit être fait au même endroit, en visant à nouveau l’environnement ; ARKit relocalise alors les cubes. Ce n’est pas une sauvegarde cloud et elle peut échouer si le lieu a trop changé ou manque de texture/lumière.

## GitHub Actions et iPhone

Le workflow compile le projet sur macOS mais ne produit volontairement pas d’IPA installable : une IPA iOS doit être signée avec un certificat et un profil Apple correspondant à l’iPhone. Pour tester gratuitement, le plus simple est de brancher l’iPhone à un Mac et d’utiliser le *Personal Team* dans Xcode ; le profil expire après 7 jours. Pour un IPA/TestFlight distribué depuis GitHub Actions, il faut en pratique une adhésion Apple Developer Program et placer le certificat, sa clé privée et le provisioning profile dans les secrets GitHub.

Les runners macOS standard sont gratuits et illimités seulement pour les dépôts GitHub publics ; un dépôt privé consomme le quota mensuel. Ne mets jamais certificats ou profils dans le dépôt.
