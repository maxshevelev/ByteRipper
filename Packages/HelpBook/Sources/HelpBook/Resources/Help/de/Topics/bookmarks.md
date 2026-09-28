@source-sha b035d4fa7a3f3785c961f3507a83c116d555a646e93fb005d94d41ac8001a003
# Lesezeichen

> Markierte Adressen, zu denen schnell zurückgekehrt werden kann: auf der Zeile angezeigt und beiden Bereichen gemeinsam.

**⌘D** setzt ein Lesezeichen auf der Zeile, auf der die Einfügemarke steht, oder entfernt ein vorhandenes. Die Adresse dieser Zeile wird dann auf einem farbigen Pfeil dargestellt, und die Zeile wird am Rand der [[topic:minimap|Minimap]] durch einen farbigen Zeiger markiert.

- **⇧⌘D** gibt dem Lesezeichen einen Namen oder ändert den vorhandenen. Ein Lesezeichen ohne Namen zeigt seine Adresse.
- **⌘L** öffnet „Gehe zu“, und die untere Hälfte dieses Fensters ist die Lesezeichenliste: Tab bringt die Tastatur hinein, Return springt zum ausgewählten Lesezeichen.

## Was ein Lesezeichen markiert

Ein Lesezeichen markiert eine **Zeile**, kein Byte: Die Adresse wird auf ein Vielfaches von 16 abgerundet, da die Zeile die Einheit ist, auf der die Markierung sichtbar ist.

Ein Lesezeichen hält eine **absolute Adresse** und gehört zum Fenster, nicht zu einer Datei. In einem Vergleich zeigen beide Bereiche dasselbe Lesezeichen auf derselben Höhe, sodass `0x1FE000` in beiden Dumps auf dieselbe Stelle verweist.

Weil die Adresse absolut ist, verschiebt das Einfügen oder Löschen von Bytes den Inhalt, nicht aber das Lesezeichen. Eine Markierung, die mit den Bytes wandert, ist ein [[topic:segments|Segmentschnitt]].

Lesezeichen bestehen, solange das Fenster besteht, nicht die Datei: Eine Datei zu schließen und wieder zu öffnen behält sie.

Welche Adressen sich zu markieren lohnen, nennen die Werkzeuge: Wird ein Knoten ausgewählt, steht seine Adresse in der Detailliste ([[topic:tools-overview|Die Werkzeugbereiche]]).
