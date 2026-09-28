@source-sha 4acb9993b2376f850452e7878b9fd1c0b3fc1d028ba27f2dff81fe0285ae44c8
# Was die Farben bedeuten

> Ein orangefarbener Hintergrund sagt „anders als in der anderen Datei“. Roter Text sagt „geändert und noch nicht gesichert“.

Die beiden Zustände sind mit Absicht getrennt, und ein Byte kann beide zugleich tragen.

## Unterschied — ein orangefarbener Hintergrund

Im Vergleichsmodus wird jedes Byte, das sich vom Byte an **derselben Adresse** in der anderen Datei unterscheidet, **orange** hinterlegt: eine lasierende Fläche über den eigenen Ebenen des Dumps, die diese daher nicht verdeckt. Sonst nutzt nichts diesen Hintergrund.

Die Farbe ist nicht einstellbar; das dunkle Erscheinungsbild nimmt ihre dunklere Variante, die ebenfalls orange ist. Die [[topic:minimap|Minimap]] kennzeichnet Unterschiede in derselben Farbe.

Ist eine Datei kürzer, gelten die Bytes, die nur die längere hat, ebenfalls als Unterschiede, und die kürzere zeigt an ihrer Stelle leere EOF-Zellen in einem eigenen, gedämpften Stil, damit ein zu kurz gelesener Dump nicht wie eine Datei voller Nullen aussieht.

## Ungesicherte Änderung — roter Text

Ein Byte, das geändert, aber noch nicht auf das Volume geschrieben wurde, erscheint **rot**. Nach dem Sichern der Datei wird das Rot aufgehoben: Das Byte steht dann so in der Datei.

Rote Bytes sind Änderungen, die nur innerhalb von ByteRipper bestehen und nicht in der Datei auf dem Volume.

## Beide Zustände zugleich

Ein Byte, das sowohl von der anderen Datei abweicht als auch geändert wurde, trägt **beide** Zustände: den Unterschieds-Hintergrund mit roten Ziffern darüber. Die Zustände sind voneinander unabhängig, und keiner verdeckt den anderen.

## Die übrigen Markierungen

- **Die Auswahl** ist die übliche Hervorhebung und verdeckt nie den Unterschied oder das Rot.
- **Suchtreffer** sind in dem Grau gefüllt, das die Plattform für eine Auswahl ohne Fokus verwendet; der aktuelle Treffer wird als angehobene gelbe Blase dargestellt. Ein Treffer auf einem abweichenden Byte wird als Unterschied dargestellt, der Vergleich hat Vorrang.
- **Eine Zeile mit Lesezeichen** hebt ihre Adresse durch einen farbigen Pfeil hervor. Markiert wird die Zeile, nicht die Bytes, und die vorstehenden Zustände bleiben davon unberührt.
- **Zonen** — die farbigen Umrisse, die ein [[topic:tools-overview|Werkzeugbereich]] zeichnet — markieren den Byte-Bereich einer Struktur. Eine Zone ist ein Umriss samt Tönung, keine Füllung, und kann deshalb über Unterschieden liegen, ohne sie zu verdecken.

ByteRipper folgt dem Erscheinungsbild des Systems, all das hat also auch eine dunkle Fassung. Die Palette steht in den [[topic:settings|Einstellungen ▸ Darstellung]].
