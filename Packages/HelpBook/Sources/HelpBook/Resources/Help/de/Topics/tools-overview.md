@source-sha a2b4850d68fb305994945dedf836b49d18432bf30a03347a65f89934d5b651d6
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

## Einen Teil entnehmen

Das Kontextmenü eines Knotens öffnet ihn als [[topic:fragments|Fragment-Bereich]]: die Bytes des Knotens als eigenes Dokument über dem Image, aus dem sie stammen. So wird ein einzelnes Modul, eine Region oder eine entpackte Sektion entnommen, untersucht und zurückgeschrieben.
