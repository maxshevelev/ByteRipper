@source-sha 4023f9be41d22bf1f0c83baa0db50d2c526009d3dab2f77433b7a4ace9821a7e
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

## Wo der Ausdruck steht

Öffnen Sie den Code eines PEIMs oder eines DXE-Treibers: Der Tab „Interfaces“ des [[topic:code-panel|Code-Bereichs]] zeigt den Ausdruck unter **Abhängigkeitsausdruck**. Jede GUID steht unter dem Namen, den ihr die Analyse gegeben hat, oder als GUID, wenn noch keine Analyse sie benannt hat. Das Image enthält nur die sechzehn Bytes.

## Wie man den Installierer einer Schnittstelle findet

Die Abhängigkeitssektionen, die eine GUID nennen, sind ihre Verbraucher. Ein Modul, das dieselbe GUID installiert, erwähnt sie meist im Code oder in den Daten. Suchen Sie im Inhalt des Images nach den sechzehn Bytes der GUID — die ersten drei Felder little-endian, die letzten acht wie gespeichert; — die Treffer enthalten beides: Abhängigkeitssektionen und Module, in deren Code oder Daten die GUID steht. Die Dekompilierung eines Kandidaten unterscheidet den Installierer, der einen Deskriptor an `InstallPpi` übergibt oder ein Protokoll installiert, vom Verbraucher, der `LocatePpi` oder `LocateProtocol` aufruft.

Der Ausdruck zeigt die Schnittstelle, die ein Modul anfordert, nicht das Modul, das sie bereitstellt. Die Schnittstellen, die ein Modul installiert, stehen in seinem Code-Bereich, sobald seine Analyse sie erfasst hat; bei einem Modul ohne Analyse ist sein dekompilierter Code zu lesen.

## Was das nicht sagen kann

Eine Installation kann bedingt sein — vom Boot-Modus, einem Strap, einem Wert aus einem HOB — und mehrere Module können dieselbe GUID installieren. Die Anzeige liest das Image so, wie es im Chip liegt, nicht so, wie die Platine läuft: Sie kann sagen, was ein Modul anfordert und welche Module in Frage kommen, aber nicht, welches bei einem bestimmten Boot geantwortet hat.
