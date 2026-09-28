@source-sha 7f14474e662ad164db0dbe90e9613188544509a2edf1bc1c6e475d34ec04e676
# Große Dumps

> Nichts wird am Stück in den Speicher geladen, deshalb öffnet sich ein großes Image so schnell wie ein kleines.

ByteRipper liest eine Datei blockweise und hält nur, was es gerade zeigt, plus einen begrenzten Cache. Ein 32-MB-SPI-Dump und ein 2-GB-Image öffnen sich gleich: sofort, mit den ersten Zeilen auf dem Bildschirm, bevor der Rest der Datei überhaupt angefasst wurde.

Daraus folgt:

- **Öffnen geht sofort**, gleich welcher Größe. Dauert es, liegt die Datei auf einem langsamen Volume oder im Netz — sie ist nicht „zu groß“.
- **Bearbeiten schreibt die Datei nicht neu.** Ihre Änderungen liegen getrennt von der Datei auf dem Volume, bis Sie sichern — deshalb sind geänderte Bytes bis dahin rot.
- **Arbeit über die ganze Datei läuft im Hintergrund.** Ein vollständiger Vergleich, eine Suche über den ganzen Dump, ein Firmware-Parse: das Fenster bleibt bedienbar, und unten im Bereich erscheint eine Fortschrittszeile mit einer Taste, die den Vorgang abbricht.
- **Der sichtbare Vergleich ist sofort da.** Was Sie sehen, wird beim Scrollen verglichen, auch während die vollständige Zahl der Unterschiede noch ermittelt wird.

Die Dateigröße setzt der Arbeit damit keine praktische Grenze. Ein voller 16-MB-SPI-Dump mit ME-Region, die zusammengefügten Dumps zweier Bausteine über 64 MB, ein eMMC-Auszug und ein Plattenabbild von mehreren Terabyte werden gleich behandelt.

Siehe auch: [[topic:minimap|Die Minimap]] — so sieht man die Gestalt einer großen Datei auf einmal.
