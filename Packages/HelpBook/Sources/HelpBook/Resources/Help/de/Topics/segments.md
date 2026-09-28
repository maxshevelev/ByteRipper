@source-sha 053c8c1a48732d591bd408ca8930f006c4ffe5c39d5e9754b65733b054ec5096
# Segmente: einen Dump in Teile schneiden

> Die inneren Grenzen eines Images markieren und jedes Teil als eigene Datei sichern.

Eine Segmentierung teilt die Datei eines Bereichs in **Segmente**: zusammenhängend, überschneidungsfrei, die Datei stets vollständig abdeckend. Jede geöffnete Datei beginnt als ein Segment — sie selbst.

An den Bytes ändert ein Segment nichts: Es ist eine Art, die Datei zu *lesen*, und geschrieben wird nur beim ausdrücklichen Sichern.

## Einen Schnitt setzen

- Ein Rechtsklick in den Dump und der Befehl **Hier bei „Adresse“ schneiden** schneiden an der Einfügemarke.
- **Bearbeiten ▸ Schnitt hinzufügen…** nimmt die Adresse als Zahl entgegen.
- **Bearbeiten ▸ Zusammenführen** entfernt den Schnitt vor dem Segment, in dem die Einfügemarke steht, und führt es mit seinem Nachbarn zusammen.
- **Bearbeiten ▸ Segmente…** (⌥⌘S) öffnet die Liste: alle Segmente, ihre Bereiche, ihre Namen und die Tasten, die auf alle zugleich wirken.

Segmente heißen **S0, S1, S2 …** in Dateireihenfolge und werden neu nummeriert, sobald ein Schnitt hinzukommt oder entfällt. Ein Name, der einem Segment gegeben wurde, bleibt bei ihm, unabhängig von seiner Nummer.

## Die Teile sichern

Das Segmentformular enthält **Alle als einzelne Dateien sichern…**, was alle Teile auf einmal schreibt. Zusammen mit [[topic:join-duplicate|Datei anhängen…]] deckt das den Fall einer Platine ab, deren Firmware in zwei SPI-Bausteinen liegt:

1. Beide Bausteine werden gelesen, was zwei Dateien ergibt.
2. Eine wird geöffnet und die andere angehängt, sodass die gesamte Firmware ein Image ist.
3. Das Image wird als eine Datei verglichen, durchsucht, bearbeitet und vom [[topic:tool-uefi|UEFI-Werkzeug]] decodiert, das ein zusammenhängendes Image erwartet.
4. Die Grenze, an der die beiden Dateien zusammentrafen, ist bereits ein Schnitt, sodass **Alle als einzelne Dateien sichern** die beiden Hälften genau an dieser Grenze zurückgibt.

! Ein Schnitt wandert mit den Bytes: Davor eingefügte Daten verschieben ihn. Ein [[topic:bookmarks|Lesezeichen]] verhält sich umgekehrt und bleibt an seiner Adresse. Ein Schnitt bezeichnet die Grenze eines Bereichs, ein Lesezeichen eine Adresse.

Segmente leben, solange die Datei offen ist.
