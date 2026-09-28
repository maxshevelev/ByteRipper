@source-sha 96ac7a7bfaedc57730e7a4f1f44b5105972083c55e0bd3ee13a9cec6cd6f94b3
# Die Werkzeugbereiche

> Werkzeuge, die den geöffneten Dump decodieren und melden, welche Strukturen er enthält.

Das Menü **Werkzeuge** schaltet jeweils einen Bereich neben dem Dump ein. Jedes Werkzeug liest die Datei des Dateibereichs, an den es gebunden ist, und zeigt seine eigene Sicht darauf:

- **[[topic:tool-uefi|UEFI-Struktur]]** — die Aufteilung eines Firmware-Images: die Flash-Regionen, die Volumes, die Dateien und Sektionen darin, die NVRAM-Speicher.
- **[[topic:tool-me|ME Analyzer]]** — was für eine Intel-Management-Engine-Firmware im Image steckt: ihre Version, ihre Partitionen, ihre Konfiguration.
- **[[topic:tool-fit|FIT-Tabelle]]** — die Firmware Interface Table und ob ihre Einträge noch auf das zeigen, was sie behaupten.

## Was sie gemeinsam haben

- **Ein Panel ist an einen Bereich gebunden.** In einem Vergleich nennt sein Kopf die Datei, die es liest, und dort gibt es ein Klappmenü, um es auf die andere zu bewegen. In den anderen Bereich zu klicken bewegt es **nicht**: ein Werkzeug liest weiter die Datei, für die es geöffnet wurde.
- **Sie lesen im Hintergrund.** Das Zerlegen eines 16-MB-Images blockiert das Fenster nie; eine Fortschrittszeile meldet es, und es lässt sich abbrechen.
- **Einen Knoten auszuwählen zeigt seine Bytes.** Ein Klick auf eine Zeile scrollt den Dump zu den Bytes, für die sie steht, und umrandet sie als **Zone**; damit ist der Name im Bereich mit einer Adresse in der Hex-Ansicht verbunden.
- **Sie sagen, worin sie unsicher sind.** Ein Feld, das niemand dokumentiert hat, behält seinen rohen Wert und heißt unbekannt, statt einen selbstsicheren Namen zu bekommen. Siehe [[topic:provenance|Woher dieses Wissen stammt]].
- **Die Zeilenmarkierungen** — die Balken, Abzeichen und Warnzeichen — erklärt der Streifen **Legende** unter der Tabelle jedes Panels.

## Ein Fragment herausholen

Klicken Sie einen Knoten mit rechts an, lässt er sich als [[topic:fragments|Fragment-Bereich]] öffnen: die Bytes des Knotens als eigenes Dokument über dem Image, aus dem sie stammen. So wird ein einzelnes Modul, eine Region oder eine entpackte Sektion herausgeholt, untersucht und zurückgeschrieben.
