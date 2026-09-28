@source-sha 316bfd9b1d66d6bb5211dd78df12a91bc89ea5574659a09d575b250b8e8bfb9c
# Bytes bearbeiten

> Schreiben Sie über das, was da ist. Alles, was die Länge der Datei ändert, fragt vorher.

Klicken Sie in die Hex-Spalte und tippen Sie Hex-Ziffern; klicken Sie in die Textspalte und tippen Sie Zeichen. Beides ändert dieselben Bytes.

In Hex ändert die erste Ziffer das obere Halbbyte und die zweite das untere, dann rückt die Einfügemarke weiter. In der Textspalte schreibt ein druckbares Zeichen sein Byte; alles, was nicht ASCII ist, wird übergangen.

## Überschreiben ist die Vorgabe, und das mit Absicht

Tippen **überschreibt**. Einsetzen (⌘V) überschreibt. Nichts rückt, nichts wandert, und jede Adresse in der Datei bedeutet weiter, was sie vorher bedeutete.

Für einen Dump ist das die richtige Vorgabe. In einem Firmware-Image ist eine Adresse eine Position auf dem Chip: eine Tabelle zeigt auf `0x800000`, eine Signatur deckt einen festen Bereich ab, eine Regionsgrenze steht im Descriptor. Fügen Sie vorn ein Byte ein, und jede dieser Angaben wird falsch.

- **Entf und Rückschritt kürzen die Datei nicht.** Sie füllen mit `0x00` — Entf das Byte an der Einfügemarke, Rückschritt das davor. Eine Auswahl wird mit `0x00` gefüllt.
- **Bearbeiten ▸ Auswahl füllen mit…** füllt die Auswahl mit einem Byte Ihrer Wahl. Auf Flash ist das meist `FF`: so sieht gelöscht aus.

## Vorgänge, die die Länge doch ändern

Es gibt sie, und jeder fragt, bevor er handelt:

- **Bearbeiten ▸ Einsetzen mit Verschieben…** — einsetzen und alles dahinter verschieben.
- **Bearbeiten ▸ Bytes löschen…** — wirklich löschen und alles dahinter verschieben.
- **Bearbeiten ▸ Einfügemodus** (⌥⌘I) — ein Tippmodus, in dem Tasten einfügen und löschen statt zu überschreiben. Er fragt einmal je Datei statt bei jedem Anschlag, sagt es in der Statuszeile und ändert die Form der Einfügemarke.

Die Rückfragen lassen sich in den [[topic:settings|Einstellungen ▸ Bearbeiten]] abschalten oder über das Kästchen „Nicht mehr fragen“ im Dialog selbst. Sie sind eingeschaltet, weil genau diese Änderungen einen strukturierten Dump still ruinieren.

! Die Länge eines SPI-Dumps darf sich nicht ändern, da die Kapazität des Bausteins fest ist. Siehe [[topic:bench-safety|Einschränkungen beim Bearbeiten eines Images]].

## Widerrufen

Jede Änderung ist ein Widerrufsschritt (⌘Z), auch die großen: ein Zusammenfügen, ein Füllen, ein Schreibvorgang eines [[topic:tools-overview|Werkzeugbereichs]], ein in die Quelle zurückgeschriebenes Fragment. Widerrufen gilt je Dokument.
