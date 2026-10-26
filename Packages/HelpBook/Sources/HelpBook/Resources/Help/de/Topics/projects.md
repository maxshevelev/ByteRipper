@source-sha ea50324c4a301b96b0d517012c29f452de2d0ff54d7ce79cca2d8e36cde37673
# Projekte

> Ein Projekt ist ein Arbeitsbereich in einer eigenen Datei: alles, was für einen Auftrag geöffnet ist, wird als Ganzes wieder geöffnet, und zwischen Projekten lässt sich wechseln.

Ein Projekt enthält dasselbe wie der [[topic:workspace|Arbeitsbereich]] — die Fenster und Tabs, die darin geöffneten Dateien, die Position in jedem Bereich, die Lesezeichen, die Segmente, die Fragment-Bereiche, die Werkzeugbereiche und das Anmerkungen-Fenster — einschließlich jeder noch nicht gesicherten Änderung: unbenannte Dokumente, Änderungen in Teilen, die noch nicht zurückgeschrieben sind, und die geänderten Bytes von Dateien auf dem Datenträger, die rot zurückkehren, wie sie waren — sowie den Widerrufsverlauf jedes Dokuments. Anders als der Arbeitsbereich wird ein Projekt unabhängig von der Einstellung **Arbeitsbereich beim Start wiederherstellen** aufbewahrt.

## Ein Projekt anlegen

**Ablage ▸ Als Projekt sichern…** schreibt alles, was gerade geöffnet ist, in eine Projektdatei mit der Endung `.brp` und macht sie zum geöffneten Projekt. Von da an wird das Projekt fortlaufend geschrieben, alle paar Sekunden und bei jedem Wechsel; einen eigenen Befehl zum Sichern gibt es nicht. Der Name des Projekts steht hinter dem Titel jedes Fensters.

Die Dateien selbst bleiben, wo sie sind; das Projekt verweist auf sie. Es merkt sich jeden Pfad, wie er ist, und zusätzlich relativ zu dem Ordner, in dem das Projekt liegt. Ein Auftragsordner mit dem Projekt und seinen Dumps lässt sich daher als Ganzes verschieben oder kopieren, auf einen anderen Datenträger oder einen anderen Mac, und die Dateien werden wiedergefunden.

## Öffnen und wechseln

- **Ablage ▸ Öffnen…**, ein Doppelklick im Finder oder ein Ziehen öffnet eine `.brp`-Datei als Projekt, nicht als Dump.
- **Ablage ▸ Benutzte Projekte** nennt die zuletzt geöffneten Projekte.
- Das Öffnen eines Projekts ersetzt alles Geöffnete. Das verlassene Projekt bleibt erhalten, wie es ist, ungesicherte Änderungen eingeschlossen, und es wird nichts gefragt.
- Ist kein Projekt geöffnet, aber etwas anderes, bietet das Programm vor dem Öffnen eines Projekts an, die aktuelle Sitzung als Projekt zu sichern. **Nicht sichern** schließt sie auf dem üblichen Weg, mit den Fragen zu ungesicherten Änderungen.
- **Ablage ▸ Projekt schließen** lässt das Projekt, wie es ist, und kehrt zu einem leeren Fenster zurück.
- Das Schließen des letzten Fensters eines Projekts — mit dem Schließknopf oder **Ablage ▸ Fenster schließen** — beendet ByteRipper genau wie **⌘Q**: Das Projekt behält seine Fenster, und es wird nichts gefragt.

Ist [[topic:workspace|Arbeitsbereich beim Start wiederherstellen]] eingeschaltet, wird das Projekt, das beim Beenden von ByteRipper geöffnet war, beim nächsten Start wieder geöffnet.

## Was eine Projektdatei ist

Eine `.brp`-Datei ist ein Paket: ein Ordner, den der Finder als eine Datei zeigt und kopiert. Es enthält `Project.json` — einige Kilobyte, die die Fenster beschreiben — und, nur solange es sie gibt, die Bytes, die sonst nirgends auf dem Datenträger liegen: unbenannte Dokumente und ungesicherte Änderungen. Ein Projekt ohne ungesicherte Arbeit bleibt klein. Um ein Projekt per Mail oder Messenger zu verschicken, wird es zuvor im Finder mit **Komprimieren** gepackt.

Eine Version von ByteRipper öffnet die Projekte, die frühere Versionen gespeichert haben. Ein Projekt, das eine neuere Version gespeichert hat, wird nicht geöffnet: Eine Meldung nennt den Grund, und das Projekt bleibt für jene Version unverändert.

## Geänderte und fehlende Dateien

Eine Datei, die weder unter ihrem Pfad noch relativ zum Projekt gefunden wird, wird nicht geöffnet. Eine Datei, die sich auf dem Datenträger geändert hat, während das Projekt geschlossen war, öffnet sich ohne die ungesicherten Änderungen des Projekts an ihr, da diese an anderen Bytes vorgenommen wurden. Eine Meldung nach dem Öffnen nennt beides, wie beim Arbeitsbereich.

## Codeanalysen im Projekt

Ein Projekt enthält auch die Codeanalysen, die seine Codebereiche zeigen — im Paket `.brp`, sodass sie sich auf einem anderen Mac ohne Ghidra öffnen. Solange das Projekt offen ist, wird eine neue Analyse eines darin gezeigten Moduls — das Modul erneut analysiert oder seine Durchsicht erneut veröffentlicht — ebenfalls ins Projekt geschrieben.

Beim Öffnen wird jede Analyse zu den auf diesem Mac gespeicherten hinzugefügt — oder, wenn die Analysen auf einem Analyseserver liegen, zu denen des Servers ([[topic:code-analyses|Codeanalysen und der Analyseserver]]). Eine hier gespeicherte Analyse wird nur durch eine spätere Revision derselben Durchsicht ersetzt; liegt die spätere Revision auf diesem Mac, wird sie gezeigt. Wird eine Analyse anders gezeigt, als das Projekt sie gesichert hat, nennt eine Meldung nach dem Öffnen dies mit der Anzahl:

- **Stattdessen wird die Analyse eines anderen Projekts gezeigt** — dieser Mac hat eine Durchsicht des Moduls aus einem anderen Ghidra-Projekt. Die Kopie des Projekts wird beiseitegelegt, nicht verworfen.
- **Stattdessen wird eine andere gespeicherte Analyse gezeigt** — dieser Mac hat eine andere, auf dieselbe Weise erstellte Analyse des Moduls.
- **Im Projekt beschädigt und nicht gelesen** — die Kopie des Projekts lässt sich nicht lesen.
