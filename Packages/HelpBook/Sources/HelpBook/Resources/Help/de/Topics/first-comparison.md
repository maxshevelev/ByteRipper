@source-sha 1bbd3b410b67a58d52108e1d1b1515f5458c7e76b18d3066a5d2cf2f9e8410bb
# Ihr erster Vergleich

> Zwei Dumps öffnen, und das Programm nennt die Adressen, an denen sie sich unterscheiden.

1. Öffnen Sie den Dump, den Sie untersuchen: **Ablage ▸ Öffnen…** (⌘O), oder ziehen Sie die Datei ins Fenster.
2. Öffnen Sie die zweite Datei auf dieselbe Weise. Sie landet im anderen Dateibereich, und der Vergleich beginnt selbsttätig.
3. Achten Sie auf die Farbe der Bytes. Jedes Byte, das sich zwischen den beiden Dateien unterscheidet, trägt den Unterschieds-Hintergrund. Eine lange Strecke Farbe bedeutet, dass ein ganzer Bereich abweicht; einzelne verstreute Zellen bedeuten, dass einzelne Bytes abweichen.
4. Bewegen Sie sich zwischen den Unterschieden: **⌥⌘→** zum nächsten, **⌥⌘←** zum vorherigen. Die Statuszeile nennt den Anteil des Images, der abweicht — `Unterschiede 0.4%` — byteweise gezählt an der Länge der längeren Datei.
5. Die Statuszeile nennt die Adresse der aktuellen Position der Einfügemarke.
6. Schalten Sie ein Werkzeug ein — **Werkzeuge ▸ UEFI-Struktur**. Es decodiert den Aufbau der Datei und legt den Dump als Baum benannter Regionen und Volumes aus. **Knoten an der Einfügemarke zeigen** im Kopf des Bereichs öffnet den Knoten dieses Baums, in den die Adresse der Einfügemarke fällt.

## Wenn die Dateien verschieden groß sind

ByteRipper vergleicht sie dennoch ab Adresse null und kennzeichnet den Rest der längeren Datei als abweichende Bytes.

Siehe auch: [[topic:navigation|Sich bewegen]], [[topic:colors|Was die Farben bedeuten]].
