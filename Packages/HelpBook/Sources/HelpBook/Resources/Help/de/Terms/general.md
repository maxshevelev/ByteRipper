@source-sha 6cc9b42e364c96f77c1258c03fa24b7881462918581844e39f2e060aec33b103
@term dump
@name Dump
@short Der Inhalt eines Chips, in eine Datei ausgelesen.

Ein Dump ist das, was ein Programmer liefert, wenn er einen Flash-Chip ausliest: jedes Byte der Reihe nach, beginnend bei Adresse null. Seine Größe ist die Größe des Chips.

Weil die Datei der Chip ist, ist ein Offset in der Datei eine Adresse auf dem Chip — deshalb vergleicht ByteRipper nach Adresse und verschiebt nie eine Datei gegen die andere.

@see topic:overview
@see term:offset

@term offset
@name Offset (Adresse)
@short Die Position eines Bytes in der Datei, von null an gezählt.

Offsets sind in ByteRipper nullbasiert und werden hexadezimal angezeigt. Offset `0` ist das erste Byte, Offset `0x1000` das 4097.

Überall, wo das Programm einen Offset entgegennimmt, braucht Hex das Präfix `0x` und Dezimal gar keines.

Bereiche sind intern halboffen: `[Anfang, Ende)`, wobei das Ende das erste Byte ist, das **nicht** dazugehört. Ein Dialog darf ein einschließendes Ende anbieten und rechnet es für Sie um.

@see topic:navigation

@term checksum
@name Prüfsumme
@short Eine kleine Zahl in einer Struktur, an der sich erkennen lässt, dass sie beschädigt wurde.

Eine Prüfsumme wird aus den eigenen Bytes einer Struktur berechnet und in ihr abgelegt. Wer die Struktur später liest, rechnet nach: stimmt es nicht überein, hat sich etwas geändert.

Das ist Arithmetik, keine Kryptografie. Nachrechnen kann sie jeder — deshalb kann ByteRipper anbieten, sie zu korrigieren, und deshalb sagt eine korrekte Prüfsumme nichts darüber, wer die Bytes geschrieben hat.

@see topic:recipe-checksums
@see term:crc

@term crc
@name CRC
@short Die kräftigere Prüfsumme, und die, die die meisten Firmware-Strukturen verwenden.

Ein CRC — hier meist CRC-32 — erkennt, was eine einfache Summe übersieht: eine Umstellung, einen verschobenen Block, eine Reihe gekippter Bits. In Firmware-Tabellen ist er verbreitet.

Wie jede Prüfsumme schützt er gegen Zufall, nicht gegen Absicht: wer die Bytes geändert hat, rechnet auch ihn nach.

@see term:checksum

@term signature
@name Signatur
@short Ein Wort für zwei Dinge: eine Magic-Kennung und eine kryptografische Signatur.

Eine **Magic-Signatur** ist eine kurze feste Zeichenfolge am Anfang einer Struktur, die sagt, was sie ist: `_FVH` bei einem Firmware-Volume, `$FPT` bei der ME-Partitionstabelle, `_FIT_` bei der Interface-Tabelle. So findet ein Parser Dinge in einem rohen Dump, und danach sucht man üblicherweise mit [[topic:search|⌘F]].

Eine **kryptografische Signatur** ist eine Zahl, die mit einem privaten Schlüssel über einen Bereich berechnet wurde. Sie beweist, wer diese Bytes hergestellt hat, und ohne den Schlüssel lässt sie sich nicht nachrechnen. Deshalb sind manche Teile eines Firmware-Images grundsätzlich nicht zu ändern.

@see term:manifest
@see term:boot-guard

@term guid
@name GUID
@short Eine 16-Byte-Kennung. UEFI benennt damit fast alles.

Eine GUID sieht so aus: `8C8CE578-8A3D-4F1C-9935-896185C32DD3`. In einem Firmware-Image werden Dateien, Sektionen, Volumes und NVRAM-Variablen über GUIDs identifiziert, nicht über Namen.

Für sich genommen bedeutet eine GUID nichts — deshalb lädt das Programm einen [[topic:databases|Gemeinschaftskatalog]] mit Namen für die bekannten. Eine Zeile mit nackter GUID ist eine Struktur, für die der Katalog keinen Namen hat — kein Fehler.

@see term:ffs-file
@see topic:databases

@term zone
@name Zone
@short Der farbige Umriss, mit dem ein Firmware-Panel einen Byte-Bereich im Dump markiert.

Wählen Sie eine Zeile in einem Firmware-Panel, veröffentlicht das Panel deren Byte-Bereich als Zone: ein Umriss samt Tönung über diesen Bytes in der Hex-Ansicht und ein Band in der [[topic:minimap|Minimap]].

Eine Zone ist ein Umriss und keine Hintergrundfüllung, verdeckt also nie einen Unterschied oder eine ungesicherte Änderung darunter.

@see topic:tools-overview
@see topic:tool-zones

@term flash-chip
@name SPI-Flash-Chip
@short Der Chip, auf dem die Firmware liegt: feste Größe, gelöscht heißt `FF`.

Ein serieller Flash-Chip trägt die Firmware der Platine. Zwei Eigenschaften zählen hier:

- **Seine Größe steht fest.** Ein Image für einen 8-MB-Chip muss exakt 8 MB groß sein. Deshalb darf am Arbeitsplatz nichts die Länge eines Dumps verändern.
- **Gelöscht heißt `FF`.** Flash wird auf Einsen gelöscht. Eine lange Kette `FF` im Dump ist leerer Raum, kein Schaden; eine lange Kette `00` ist dagegen meist beschriebene Fläche.

@see topic:bench-safety

@term programmer
@name Programmer
@short Die Hardware, die den Chip liest und schreibt. ByteRipper spricht nicht mit ihr.

ByteRipper arbeitet mit Dateien. Die Bytes vom Chip zu holen und wieder daraufzuschreiben ist Sache des Programmers — Clip, Sockel oder In-Circuit-Verbindung, mit seiner eigenen Software.

Diese Trennung ist Absicht: das Programm lässt sich mit dem Dump jedes Programmers benutzen, und es kann niemals versehentlich auf eine Platine schreiben.
