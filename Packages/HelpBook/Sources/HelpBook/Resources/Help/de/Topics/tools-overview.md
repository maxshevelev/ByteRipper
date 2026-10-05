@source-sha c4f21cbe3ca0f48b0d55eec5d7ba9e3c2fd50b1d3a52ee4b8a0e27601c1e586c
# Die Werkzeugbereiche

> Werkzeuge, die den geöffneten Dump decodieren und melden, welche Strukturen er enthält.

Das Menü **Werkzeuge** schaltet jeweils einen Bereich neben dem Dump ein. Jedes Werkzeug liest die Datei des Dateibereichs, an den es gebunden ist, und zeigt seine eigene Sicht darauf:

- **[[topic:tool-uefi|UEFI-Struktur]]** — die Aufteilung eines Firmware-Images: die Flash-Regionen, die Volumes, die Dateien und Sektionen darin, die NVRAM-Speicher.
- **[[topic:tool-me|ME Analyzer]]** — was für eine Intel-Management-Engine-Firmware im Image steckt: ihre Version, ihre Partitionen, ihre Konfiguration.
- **[[topic:tool-fit|FIT-Tabelle]]** — die Firmware Interface Table und ob ihre Einträge noch auf das zeigen, was sie behaupten.

Die Werkzeuge haben die Tasten **⌘1**, **⌘2**, **⌘3** in der Reihenfolge des Menüs; **⌘0** schließt den Bereich. Die Taste des gerade gezeigten Werkzeugs bewirkt nichts.

## Was sie gemeinsam haben

- **Ein Werkzeug ist an einen Bereich gebunden.** In einem Vergleich nennt der Kopf des Bereichs die Datei, die gelesen wird, und ein Menü dort bewegt das Werkzeug auf den anderen Bereich. In den anderen Bereich zu klicken bewegt es **nicht**: Es liest weiter die Datei, für die es geöffnet wurde.
- **Das Decodieren läuft im Hintergrund.** Das Zerlegen eines 16-MB-Images blockiert das Fenster nicht; eine Fortschrittszeile meldet es, und es lässt sich abbrechen.
- **Einen Knoten auszuwählen zeigt seine Bytes.** Ein Klick auf eine Zeile scrollt den Dump zu den Bytes, für die sie steht, und umrandet sie als **Zone**; damit ist der Name im Bereich mit einer Adresse in der Hex-Ansicht verbunden.
- **Unsicherheit wird gemeldet.** Ein Feld, das nicht dokumentiert ist, behält seinen Rohwert und wird als unbekannt bezeichnet, statt einen sicher klingenden Namen zu bekommen. Siehe [[topic:provenance|Woher dieses Wissen stammt]].
- **Die Zeilenmarkierungen** — die Balken, Abzeichen und Warnzeichen — erklärt der Streifen **Legende** unter der Tabelle jedes Bereichs.
- **Die Details lassen sich groß anzeigen.** Die **Leertaste** auf der ausgewählten Zeile oder die Schaltfläche zum Vergrößern oben rechts in den Details unter der Tabelle öffnet dieselben Details in einer großen Ansicht rechts im Fenster: Sie nimmt drei Viertel seiner Breite ein, links bleibt die Tabelle sichtbar. Solange die Ansicht offen ist, sind die Details unter der Tabelle ausgeblendet, und die Tabelle nimmt die ganze Höhe des Bereichs ein. In der Ansicht steht an ihrer Stelle eine Schaltfläche zum Schließen; ebenso schließen die **Leertaste**, **Esc** und ein Klick außerhalb der Ansicht sie, wobei dieser Klick zugleich seine gewohnte Wirkung hat, und ein Klick auf einen Link darin schließt sie und folgt dem Link. Solange sie offen ist, bewegen die Pfeiltasten weiterhin die Auswahl in der Tabelle, und die Ansicht zeigt die Details der ausgewählten Zeile.

## Einen Teil entnehmen

Das Kontextmenü eines Knotens öffnet ihn als [[topic:fragments|Fragment-Bereich]]: die Bytes des Knotens als eigenes Dokument über dem Image, aus dem sie stammen. So wird ein einzelnes Modul, eine Region oder eine entpackte Sektion entnommen, untersucht und zurückgeschrieben.
