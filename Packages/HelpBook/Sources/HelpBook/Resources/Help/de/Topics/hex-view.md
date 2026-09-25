@source-sha b4b5c6e52139d632a56c7ed3a1afc0900ef0effbaf7c20d92f685dada0e05be6
# Die Hex-Ansicht lesen

> Sechzehn Bytes je Zeile, der Offset links, der Text rechts.

Jeder Bereich zeigt seine Datei als gewöhnlichen Hex-Dump:

- **Die Offset-Spalte** links ist die Adresse des ersten Bytes der Zeile, hexadezimal und nullbasiert. Am Arbeitsplatz zählt diese Zahl: sie ist die Position auf dem Chip.
- **Sechzehn Byte-Werte** je Zeile, je zwei Hex-Ziffern in Großbuchstaben, in zwei Achtergruppen geteilt, damit das Auge mitzählen kann.
- **Der decodierte Text** rechts. Die Bytes `0x20`–`0x7E` erscheinen als Zeichen, alles andere als Punkt. Andere Codierungen lassen sich in den Einstellungen wählen.

## Was gut zu wissen ist

- **Alles zählt ab null.** Offset `0x1000` ist das 4097. Byte der Datei und, bei einem geraden SPI-Lesevorgang, das Byte an Adresse `0x1000` des Chips.
- **`0xFF` heißt leer.** Gelöschter Flash liest sich als `FF`. Ein Bildschirm voll `FF` ist kein Schaden, sondern ein Teil des Chips, in den nie jemand geschrieben hat. Ein Bildschirm voll `00` ist dagegen meist etwas: eine genullte Region, keine gelöschte.
- **Wortbreite.** **Darstellung ▸ Wortbreite** gruppiert die Bytes zu zweit, viert oder acht. Nützlich beim Lesen einer Tabelle von 32-Bit-Werten; es ändert nur den Abstand, nie die Reihenfolge und nie die Adressen.
- **Zoom.** **⌘=** und **⌘−** ändern die Schriftgröße überall. Schrift, Größe und Zeilenhöhe stehen in den [[topic:settings|Einstellungen ▸ Darstellung]].

## Die Statuszeile

Unter jedem Bereich: der Offset der Einfügemarke, die Größe der Auswahl, sofern vorhanden, die Größe der Datei und das Segment, in dem die Einfügemarke steht, wenn der Bereich [[topic:segments|Segmente]] hat. Auch eine Hintergrundarbeit — ein vollständiger Vergleich, eine Suche, ein Firmware-Parse — meldet sich hier, samt einer Möglichkeit abzubrechen.

Siehe auch: [[topic:colors|Was die Farben bedeuten]], [[topic:navigation|Sich bewegen]].
