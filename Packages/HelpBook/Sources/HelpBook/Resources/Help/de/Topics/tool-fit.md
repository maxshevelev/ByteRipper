@source-sha ea55a269d83a82fc01f731d02303cfa262e5302e136000bb2fbb81e99856b48f
# FIT-Tabelle

> Die Firmware Interface Table: was der Prozessor laden soll, bevor er Firmware-Code ausführt, und ob diese Bauteile vorhanden sind.

**Werkzeuge ▸ FIT-Tabelle** findet die [[term:fit|Firmware Interface Table]] im Image und führt ihre Einträge auf.

Die Tabelle liegt nahe der oberen Grenze des Flash-Speichers und wird über einen Zeiger an einer festen Adresse knapp unterhalb von `4 GB` erreicht. Jeder Eintrag trägt eine Adresse, eine Größe und einen Typ: ein [[term:microcode|Microcode-Update]], ein ACM, ein Boot-Guard-Manifest, einen TXT-Policy-Eintrag.

## Was das Werkzeug meldet

- **Die Einträge** mit Typ, Adresse und Größe, in der Reihenfolge der Tabelle.
- **Was an jeder Adresse tatsächlich liegt.** Die Spalte **Zeigt auf** wird nicht aus dem Eintrag gelesen: Das Werkzeug folgt der Adresse und meldet, was dort steht — ein Microcode-Update mit gültigem Header, ein Manifest, ein gelöschter Bereich oder nichts Erkennbares.
- **Die Regeln der Tabelle**: den Header-Eintrag, die Anzahl der Einträge, die Prüfsumme, die Reihenfolge der Einträge nach Typ, die Ausrichtung der Adressen, das reservierte Byte sowie die Übereinstimmung mit der [[term:top-swap|Top-Swap]]-Sicherungskopie, sofern das Image eine führt. Die gefundenen Verstöße stehen unter der Tabelle; ein Doppelklick auf einen bringt den Dump zu den betroffenen Bytes.
- **Den Namen jedes Microcodes**, aus einem Online-Katalog nach Prozessorsignatur, Revision und Datum. Siehe [[topic:databases|Die Online-Kataloge]]; ohne Netzzugang werden die Kennungen gemeldet und die Namen weggelassen.

## Was das Werkzeug ändert

Das Werkzeug liest das Image nicht nur, es schreibt auch hinein. Jeder Vorgang bildet einen Widerrufsschritt, und keiner von ihnen ändert die Länge der Datei.

- **Microcode hinzufügen…** in der Kopfzeile des Bereichs legt ein Microcode-Bauteil in das Image und trägt es in die Tabelle ein. Die angebotene Liste wird aus einem Online-Katalog geladen; **Datei wählen…** nimmt einen Microcode stattdessen aus einer lokalen Datei.
- **Microcode ersetzen** tauscht das von einer Zeile benannte Bauteil gegen ein anderes.
- **Microcode entfernen** nimmt einen Eintrag aus der Tabelle und rückt die Bauteile dahinter nach.
- **Prüfsumme korrigieren** in der Header-Zeile schreibt die Prüfsumme, die die Tabelle tragen müsste.
- **CPUID kopieren** und **Zum Offset springen** stehen im Kontextmenü einer Zeile.

Unter welchen Bedingungen diese Befehle abgelehnt werden und was jeder von ihnen schreibt, steht unter [[topic:recipe-microcode|Microcode und die FIT-Tabelle]].

! Führt das Image eine Top-Swap-Sicherungskopie des Blocks, in dem die Tabelle liegt, wird eine Änderung in beiden Kopien vorgenommen; weichen die Kopien voneinander ab, lehnt das Werkzeug die Änderung ab. Eine Änderung, die einen von [[term:boot-guard|Boot Guard]] geschützten Bereich berührt, wird grundsätzlich abgelehnt.

Siehe auch: [[topic:recipe-microcode|Microcode und die FIT-Tabelle]], [[term:top-swap|Top Swap]].
