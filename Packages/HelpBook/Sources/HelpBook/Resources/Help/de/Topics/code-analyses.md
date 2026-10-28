@source-sha 557f81f7f44aee55a820aec737edec2e0cf7562c9260210fc3956f5f92a03e23
# Codeanalysen und der Analyseserver

> Eine Codeanalyse ist das, was Ghidra in einem PEI- oder DXE-Modul gefunden hat: seine Funktionen, Befehle und den dekompilierten C-Code sowie die Namen, die eine Durchsicht ihnen gegeben hat. ByteRipper liest Analysen aus einem Speicher — einem Ordner auf diesem Mac oder einem Analyseserver, den alle Macs eines Netzwerks gemeinsam nutzen.

Eine Analyse erstellt der Ghidra-Skill außerhalb von ByteRipper. ByteRipper liest, was der Skill gespeichert hat: Ein Modul des UEFI-Baums, zu dem eine Analyse vorliegt, trägt ein Code-Symbol, und **Mit Code öffnen** zeigt seinen Code neben seinen Bytes; der Bereich ist auf [[topic:code-panel|Code-Bereich]] beschrieben. Solange die Datei des Moduls zugeklappt ist, steht das Symbol hinter dem Namen der Datei; eine Liste zugeklappter Dateien zeigt so, für welche Module eine Analyse vorliegt. Beim Aufklappen der Datei wandert das Symbol zu dem Abschnitt, der das Modul enthält. Eine Analyse ist den Bytes des Moduls zugeordnet, nicht dem Dump; dasselbe Modul in einem anderen Dump öffnet daher dieselbe Analyse.

## Wo die Analysen liegen

Der Speicher wird unter **Einstellungen ▸ Codeanalyse** gewählt.

- **Auf diesem Mac** — die Analysen werden aus dem eigenen Ordner dieses Macs gelesen, `~/Library/Application Support/ByteRipper/Analysis`. Dorthin schreibt der Ghidra-Skill, wenn er auf diesem Mac läuft. Diese Einstellung gilt für einen einzelnen Mac.
- **Auf einem Analyseserver** — die Analysen werden von `byteripper-server` gelesen, einem Programm auf einem Rechner im Netzwerk. Alle Macs, die denselben Server angeben, lesen dieselben Analysen; ein einmal analysiertes oder durchgesehenes Modul steht damit allen zur Verfügung.

Die Einstellung legt nur fest, woher die Analysen gelesen werden. Beim Umstellen wird nichts kopiert oder gelöscht: Der Ordner auf diesem Mac bleibt unverändert, und mit **Auf diesem Mac** sind seine Analysen wieder sichtbar.

## Verbindung mit einem Server

Der Server wird einmal eingerichtet, im Terminal des Rechners, auf dem er läuft:

1. `byteripper-server token` erzeugt das Token und gibt es aus.
2. `byteripper-server --listen 127.0.0.1:8765 --listen 100.64.0.7:8765` startet den Server unter den angegebenen Adressen: der Loopback-Adresse für ByteRipper auf dem Server selbst — ein Mac erreicht seine eigene Adresse in einem privaten Netzwerk wie Tailscale nicht — und der Adresse im privaten Netzwerk für die anderen Macs.

Auf jeder Adresse außer der Loopback-Adresse des Rechners selbst startet der Server nur mit einem Token. Üblich ist die Adresse des Servers in einem privaten Netzwerk wie Tailscale, das die Verbindung zudem verschlüsselt.

Auf jedem Mac unter **Einstellungen ▸ Codeanalyse**:

1. **Auf einem Analyseserver** wählen.
2. Die Adresse in der Form `http://host:port` — auf dem Server selbst `http://localhost:8765` — und das vom Server ausgegebene Token eingeben.
3. Auf **Verbinden** klicken.

Die Zeile unter den Feldern zeigt, ob der Server erreichbar ist. Das Token liegt in einer Datei, die nur der angemeldete Benutzer lesen kann, `~/Library/Application Support/ByteRipper/Server/token`; dieselbe Datei lesen die Skripte des Ghidra-Skills auf diesem Mac. Bleibt das Tokenfeld leer, wird das bereits gespeicherte Token verwendet.

## Arbeiten mit einem Server

- **Neue Analysen erscheinen von selbst.** Der Server meldet jede Änderung sofort; eine von einem beliebigen Rechner gespeicherte Analyse oder veröffentlichte Durchsicht erscheint daher binnen ein bis zwei Sekunden auf allen Macs, und eine offene Codepalette wird an derselben Stelle neu aus ihr aufgebaut.
- **Bereits Gelesenes bleibt lesbar.** Dieser Mac behält eine Kopie dessen, was er vom Server gelesen hat. Ist der Server nicht erreichbar, meldet die Zeile in den Einstellungen dies; bereits gelesene Analysen werden weiter gezeigt, noch nicht gelesene nicht. Die Verbindung wird selbsttätig erneut aufgebaut.
- **Projekte nutzen den Server.** Beim Öffnen eines Projekts werden die Analysen, die es enthält, an den Server gesendet, der sie nach den üblichen Regeln übernimmt (siehe [[topic:projects|Projekte]]); die Meldung nach dem Öffnen gibt die Antwort des Servers wieder.

## Durchsicht durch einen Agenten

Betreibt der Analyseserver auch Ghidra, kann ein mit ByteRipper verbundener Agent (siehe [[topic:agent|Mit einem Agenten arbeiten]]) dort ein Modul durchsehen: Er öffnet das Modul über einen PE32- oder TE-Image-Knoten des UEFI-Baums, benennt Funktionen, Variablen und Typen, schreibt Kommentare und veröffentlicht das Ergebnis. Jede Veröffentlichung ist eine neue Revision der Analyse des Moduls, und jeder Mac, der den Server liest, zeigt sie. Das Ghidra-Projekt bleibt auf dem Server; eine Durchsicht lässt sich daher später fortsetzen, durch den Agenten oder durch eine Person. Ein Agent, der auf dem Server selbst läuft, verbindet sich direkt mit `byteripper-server` unter der Adresse `/mcp`.

## Die Analysen dieses Macs senden

**Analysen dieses Macs an den Server senden** kopiert jede Analyse aus dem Ordner dieses Macs auf den Server. Das ist für die erste Verbindung gedacht, wenn dieser Mac Analysen hat, die dem Server fehlen. Der Server übernimmt jede Analyse nach denselben Regeln wie die eines Projekts: Eine spätere Revision einer Durchsicht ersetzt eine frühere, die Durchsicht eines Moduls aus einem anderen Projekt wird beiseitegelegt, statt die vorhandene zu ersetzen, und eine bereits vorhandene Analyse bleibt unverändert. Die Zeile unter der Schaltfläche nennt die Anzahlen.

## Was der Server nicht tut

- Er ist für das Netzwerk einer einzelnen Person gedacht: Es gibt ein Token, und wer es besitzt, kann jede Analyse lesen und schreiben.
- Er löscht nichts über das Netzwerk. Nicht mehr benötigte Analysen werden auf dem Server selbst mit `byteripper-cas gc` entfernt.
- Er speichert keine Dumps. Eine Analyse vermerkt, welches Modul sie beschreibt, nie die Firmware, aus der es stammt.
