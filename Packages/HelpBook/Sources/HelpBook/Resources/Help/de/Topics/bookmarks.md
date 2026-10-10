@source-sha 5f952d99dd534e65f99f2cd7452f4c75bfecf46bdbd9645d5ac28408921405f0
# Lesezeichen

> Markierte Adressen, zu denen schnell zurückgekehrt werden kann: auf der Zeile angezeigt und beiden Bereichen gemeinsam.

**⌘D** setzt ein Lesezeichen auf der Zeile, auf der die Einfügemarke steht, oder entfernt ein vorhandenes. Der Eintrag im Menü „Bearbeiten“ nennt die jeweilige Aktion: auf einer Zeile ohne Lesezeichen **Bearbeiten ▸ Lesezeichen setzen**, auf einer Zeile mit Lesezeichen **Bearbeiten ▸ Lesezeichen löschen**. Die Adresse einer Zeile mit Lesezeichen wird auf einem violetten Pfeil dargestellt, und die Zeile wird in derselben Farbe am Rand der [[topic:minimap|Minimap]] markiert.

Das Kontextmenü (Rechtsklick) wirkt auf die angeklickte Zeile und nennt deren Adresse. Hat die Zeile kein Lesezeichen, enthält es *Lesezeichen auf Zeile … setzen*; hat sie eines, enthält es *Lesezeichen auf Zeile … löschen* und *Lesezeichen bearbeiten…*.

- **⇧⌘D** gibt dem Lesezeichen einen Namen oder ändert den vorhandenen. Ein Lesezeichen ohne Namen zeigt seine Adresse.
- **⌘L** öffnet „Gehe zu“, und die untere Hälfte dieses Fensters ist die Lesezeichenliste: Tab bringt die Tastatur hinein, Return springt zum ausgewählten Lesezeichen.

## Was ein Lesezeichen markiert

Ein Lesezeichen markiert eine **Zeile**, kein Byte: Die Adresse wird auf ein Vielfaches von 16 abgerundet, da die Zeile die Einheit ist, auf der die Markierung sichtbar ist.

Ein Lesezeichen hält eine **absolute Adresse** und gehört zum Fenster, nicht zu einer Datei. In einem Vergleich zeigen beide Bereiche dasselbe Lesezeichen auf derselben Höhe, sodass `0x1FE000` in beiden Dumps auf dieselbe Stelle verweist.

Weil die Adresse absolut ist, verschiebt das Einfügen oder Löschen von Bytes den Inhalt, nicht aber das Lesezeichen. Anders als ein Lesezeichen ist ein [[topic:segments|Segmentschnitt]] eine Markierung, die mit den Bytes wandert, wenn sich Daten in der Datei verschieben.

Lesezeichen bestehen, solange das Fenster besteht, nicht die Datei: Eine Datei zu schließen und wieder zu öffnen behält sie.

Welche Adressen sich zu markieren lohnen, nennen die Werkzeuge: Wird ein Knoten ausgewählt, steht seine Adresse in der Detailliste ([[topic:tools-overview|Die Werkzeugbereiche]]).
