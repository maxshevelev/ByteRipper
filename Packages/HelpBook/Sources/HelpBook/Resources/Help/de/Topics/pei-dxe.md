@source-sha 46f5e3297873ef859ee867ea1f4a596b1ee709ca3a5fa7c4682d80c6d7e8dcbd
# PEIMs und DXE-Treiber

> PEIMs, DXE-Treiber, die Schnittstellen, die sie veröffentlichen und erwarten, und wie der Dispatcher entscheidet, wann ein Modul läuft.

Die Firmware, die vor dem Betriebssystem läuft, ist eine Kette von Modulen; jedes ist eine Datei in einem Firmware-Volume. Der erste Teil der Kette ist PEI, der zweite DXE. Diese Seite erklärt die Wörter, die die Anzeige für beide verwendet, und wie ein Modul zur Ausführung kommt.

## Die Phasen

- SEC — Security Phase. Die ersten Befehle nach dem Reset: ein vorläufiger Stack, Cache-as-RAM, die Prüfungen der Platine und das erste Firmware-Volume, dessen PEI Core sie startet.
- PEI — Pre-EFI Initialization. Eine kleine Umgebung, in der der dauerhafte Speicher noch eingerichtet wird. Ihre Module sind PEIMs; sie veröffentlichen [[term:ppi|PPIs]] füreinander.
- DXE — Driver Execution Environment. Die vollständige Boot-Umgebung. Ihre Module sind DXE-Treiber; sie veröffentlichen Protokolle, und hier entstehen die Boot-Services, die das Betriebssystem später nutzt.

## Die Wörter

- PEIM — PEI-Modul: eine [[term:ffs-file|FFS-Datei]] vom Typ PEIM (`0x06`), gelesen als [[term:peim|PEIM]].
- PPI — PEIM-to-PEIM Interface: eine GUID und eine Tabelle von Funktionen oder ein Datenstück, das ein PEIM für die anderen veröffentlicht.
- Protokoll — dasselbe in DXE: eine GUID und eine Tabelle von Funktionen, von einem Treiber veröffentlicht und über die Boot-Services gefunden.
- DEPEX — Abhängigkeitsausdruck: der Bytecode, der die PPIs oder Protokolle nennt, die ein Modul zum Ausführen braucht.
- TE, PE32 — die Image-Formate, in denen der Code eines Moduls liegt. Ein PEIM ist meist TE, ein DXE-Treiber meist PE32.

## Wie ein Modul ausgeführt wird

Der PEI Core geht die Dateien eines Firmware-Volumes in ihrer physischen Reihenfolge durch. Für jedes PEIM wertet er den Abhängigkeitsausdruck gegen die bisher installierten PPIs aus. Ist der Ausdruck wahr, ruft er den Einstiegspunkt des PEIM auf, und dieses kann eigene PPIs installieren. Ist er falsch, bleibt das Modul für einen späteren Durchlauf liegen. Wenn ein Durchlauf nichts ausführt und Module übrig bleiben, sind ihre Abhängigkeiten nicht erfüllbar.

Der DXE-Dispatcher macht dasselbe mit Protokollen: er geht das DXE-Volume durch, wertet den Abhängigkeitsausdruck jedes Treibers aus und ruft den Treiber auf, wenn die genannten Protokolle vorhanden sind.

Ein Ausdruck steht in Postfix-Form: `PUSH` einer GUID, dann verbinden `AND`, `OR` und `NOT` die Werte, `END` schließt ab; `TRUE` und `FALSE` sind Literale. Ein DXE-Ausdruck darf außerdem mit `BEFORE`, `AFTER` oder `SOR` beginnen; sie sagen, wann der Treiber ausgeführt wird, nicht ob.

Daraus folgt etwas Wichtiges: Ein Ausdruck nennt eine **Schnittstelle**, kein Modul. Jedes Modul kann ein PPI oder Protokoll installieren, mehrere können dasselbe installieren, und manche installiert der PEI Core selbst. Das Image speichert nicht „Modul A hängt von Modul B ab“.

## Was die Anzeige zeigt

Wählen Sie ein PEIM oder einen DXE-Treiber in [[topic:tool-uefi|UEFI Structure]]: Die Details zeigen **Abhängigkeiten** — den Ausdruck als Formel über die GUIDs, mit dem Namen aus dem Katalog, sofern er einen kennt, und eine Tabelle aller Operationen mit Adresse und der GUID des PPIs oder Protokolls. Dieselben Zeilen stehen in den Details der Abhängigkeitssektion selbst — Typ `0x1B` für PEI, `0x13` für DXE, `0x1C` für MM. Ein Modul ohne Abhängigkeitssektion zeigt dieses Feld nicht.

Eine GUID, die der Katalog nicht kennt, erscheint als GUID: Das Image enthält nur sechzehn Bytes. Die Namen stammen aus dem Katalog, mit dem der Baum die GUIDs von Dateien benennt (`common/guids.csv` von UEFITool), nicht aus der Firmware.

## Wie man den Installierer einer Schnittstelle findet

Die Abhängigkeitssektionen, die eine GUID nennen, sind ihre Verbraucher. Ein Modul, das dieselbe GUID installiert, erwähnt sie meist im Code oder in den Daten. Suchen Sie im Inhalt des Images nach den sechzehn Bytes der GUID — die ersten drei Felder little-endian, die letzten acht wie gespeichert; — die Treffer enthalten beides: Abhängigkeitssektionen und Module, in deren Code oder Daten die GUID steht. Die Dekompilierung eines Kandidaten unterscheidet den Installierer, der einen Deskriptor an `InstallPpi` übergibt oder ein Protokoll installiert, vom Verbraucher, der `LocatePpi` oder `LocateProtocol` aufruft.

Die Anzeige liest Struktur, nicht Code: Sie kann die Schnittstelle zeigen, die ein Modul anfordert, nicht das Modul, das sie bereitstellt. Für den letzten Schritt braucht es einen Disassembler; die Installiereranalyse ist ein eigener Durchlauf über den Code der Module.

## Was das nicht sagen kann

Eine Installation kann bedingt sein — vom Boot-Modus, einem Strap, einem Wert aus einem HOB — und mehrere Module können dieselbe GUID installieren. Die Anzeige liest das Image so, wie es im Chip liegt, nicht so, wie die Platine läuft: Sie kann sagen, was ein Modul anfordert und welche Module in Frage kommen, aber nicht, welches bei einem bestimmten Boot geantwortet hat.
