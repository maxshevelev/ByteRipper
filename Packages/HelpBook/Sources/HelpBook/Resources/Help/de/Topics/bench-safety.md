@source-sha a27b4712e300d9955d29180c4f4a2009cd6b5b7d029a736900a973967e7470b1
# Regeln am Arbeitsplatz

> Die kurze Liste der Wege, einen Dump zu ruinieren, und wie man es lässt.

## Bewahren Sie das Original

Sichern Sie das Lesen des Chips genau so, wie es vom Programmer kam, und ändern Sie diese Datei nie. Arbeiten Sie mit einer Kopie — oder nehmen Sie **Ablage ▸ Duplizieren** und ändern Sie das Duplikat. Eine Platine mit ausgefallener Versorgung übersteht ein zweites Lesen vielleicht nicht.

## Ändern Sie nie die Länge eines Flash-Images

Ein Chip hat eine feste Größe. Jede Adresse in einem Firmware-Image ist absolut: der Descriptor nennt Regionsgrenzen, die [[term:fit|FIT]] zeigt über Adressen auf Microcode, eine Signatur deckt einen festen Bereich ab.

Überschreiben und Füllen sind sicher. „Einsetzen mit Verschieben“, „Bytes löschen“ und der Einfügemodus sind es bei einem Dump nicht — deshalb fragt das Programm vor jedem davon. Prüfen Sie vor dem Schreiben die Dateigröße im Bereichskopf gegen die Größe des Chips.

## Denken Sie an das, was platinenspezifisch ist

Ein Spenderdump aus dem Netz trägt die Identität des Spenders. Schreiben Sie ihn roh, kommt die Platine mit fremder MAC-Adresse, fremder Seriennummer und fremder Maschinen-UUID hoch — oder ganz ohne, womit manche Firmware nicht startet. Siehe [[topic:recipe-board-data|Platinenspezifische Daten bewahren]].

## Signierte und gesperrte Regionen

Moderne Intel-Plattformen prüfen Teile des Images, bevor die CPU sie ausführt, und der Descriptor kann Regionen gegen Schreiben sperren.

- Hat das Image geschützte Bereiche von [[term:boot-guard|Boot Guard]], sagt das [[topic:tool-uefi|UEFI-Panel]] es in seiner Übersichtszeile. Bytes darin lassen sich nicht ändern, ohne dass die Plattform den Start verweigert: die Signatur passt nicht mehr, und neu berechnen können Sie sie nicht.
- Die [[term:me-region|ME-Region]] prüft die Engine selbst. Sie von Hand zu ändern ergibt in aller Regel eine Platine, die hängt oder im Takt neu startet, und keine mit geänderter ME.
- Die Master-Rechte im Descriptor entscheiden, was ein Programmer schreiben darf, der **auf der Platine** läuft. Ein externer Programmer am Chip übergeht sie.

Das vor dem Ändern zu wissen ist der Unterschied zwischen einer Fünf-Minuten-Reparatur und einem Briefbeschwerer.

## Prüfen Sie vor dem Schreiben

1. Kein Rot mehr — jede Änderung ist gesichert ([[topic:saving|Sichern]]).
2. Die Dateigröße ist exakt die Chipgröße.
3. Haben Sie einen Header geändert, stimmt seine Prüfsumme; das [[topic:tool-uefi|UEFI-Panel]] markiert falsche und kann sie korrigieren.
4. Vergleichen Sie die geänderte Datei ein letztes Mal mit dem ursprünglichen Lesen ([[topic:first-comparison|Vergleich]]) und sehen Sie sich jeden Unterschied an. Jeder sollte eine Änderung sein, die Sie so wollten.
