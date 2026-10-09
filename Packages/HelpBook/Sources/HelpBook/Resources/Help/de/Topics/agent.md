@source-sha 27e3235718b318be7fa04994df555b847fd91fa476712b2a22e459e35df75ad6
# Mit einem Agenten arbeiten

> ByteRipper lässt sich mit einem Agenten verbinden — Claude Code, Claude Desktop oder einem anderen Programm, das MCP spricht. Der Agent sieht dann die im Programm geöffneten Dateien, liest ihre Bytes und zeigt Stellen darin; das Gespräch mit ihm findet in seinem eigenen Fenster statt.

Der Agent arbeitet mit denselben Fenstern wie die Person am Arbeitsplatz. Wird er nach „diesem“ Byte gefragt, liest er die Position des Cursors und die Auswahl; verweist er auf eine Stelle im Dump, scrollt er die Ansicht dorthin und wählt sie aus. Beide zeigen so auf dieselben Bytes, statt einander Adressen zu beschreiben.

## Den Dienst einschalten

Nach der Installation ist der Dienst ausgeschaltet. Eingeschaltet wird er unter **Einstellungen ▸ Agent** mit **Agenten die Verbindung mit ByteRipper erlauben**. Solange er eingeschaltet ist, erscheint ein Symbol in der Menüleiste am oberen Bildschirmrand; während ein Agent verbunden ist, ist es gefüllt.

Die Verbindung ist lokal. ByteRipper legt in der Library des Benutzers eine Datei an, über die nur Programme desselben Benutzerkontos es erreichen; ein Netzwerkport wird nicht geöffnet.

Die Bytes, die ein Agent liest, gibt sein Programm allerdings an das Modell weiter, auf dem er beruht. Bei Claude ist das der Dienst von Anthropic. Ein Dump, der die Werkstatt nicht verlassen darf, wird nicht geöffnet, solange ein Agent verbunden ist.

## Ein Programm verbinden

Unter **Einstellungen ▸ Agent** wählt das Menü **Konfiguration für:** das Programm, in dem der Agent läuft. Der Text, den dieses Programm braucht, steht vollständig darunter, mit einer Zeile, wohin er gehört; **Kopieren** legt ihn in die Zwischenablage:

- **Claude Code** — ein Befehl für das Terminal. Einmal ausgeführt, meldet er ByteRipper bei Claude Code für alle Ordner an.
- **Claude Desktop** — ein JSON-Block für die Konfigurationsdatei von Claude Desktop, `~/Library/Application Support/Claude/claude_desktop_config.json`. Claude Desktop liest sie beim Start.
- **Cursor** — derselbe JSON-Block, für `~/.cursor/mcp.json` (alle Projekte) oder `.cursor/mcp.json` in einem einzelnen Projekt.
- **Anderer Client** — die Parameter einzeln: der Name `byteripper`, der Transport `stdio`, der Befehl; Argumente und Umgebungsvariablen gibt es keine. Genau das fragt ein Client in einem eigenen Formular ab.

Führt eine Konfigurationsdatei bereits andere Server auf, kommt der Eintrag `byteripper` daneben, in dasselbe `mcpServers`.

Jede Form verweist auf das Hilfsprogramm in genau dieser Kopie von ByteRipper. Wird ByteRipper in einen anderen Ordner verschoben, ist der Text erneut zu kopieren.

Läuft ByteRipper nicht, wenn das Programm des Agenten startet, startet das Hilfsprogramm es. Ist der Dienst ausgeschaltet, meldet das Programm des Agenten, dass der Agentendienst von ByteRipper nicht läuft.

## Was ein Agent kann

Derzeit kann ein Agent:

- die geöffneten Dateien auflisten, mit Namen, Größe und der Angabe, ob ungesicherte Änderungen vorliegen;
- die Position des Cursors, die Auswahl und die sichtbaren Zeilen abfragen;
- Bytes lesen — als Hex-Zeilen, als Text oder als 16-, 32- und 64-Bit-Zahlen —, ungesicherte Änderungen eingeschlossen;
- eine Stelle zeigen: ihren Tab nach vorn holen, dorthin scrollen und sie auswählen;
- die Struktur eines Firmware-Images so lesen, wie **UEFI-Struktur** sie zeigt — den Baum, die Felder eines Knotens, die Knoten, die eine Adresse enthalten — und darin nach Name, GUID oder Typ suchen. Das geht unabhängig davon, ob der Bereich geöffnet ist;
- die FIT-Tabelle so lesen, wie **FIT-Tabelle** sie zeigt — ihre Einträge, worauf jeder verweist, welche Regeln der Spezifikation sie verletzt —, und die Intel-ME-Firmware so, wie **ME Analyzer** sie zeigt: die Übersicht und die dekodierte Struktur. Auch das geht bei geschlossenen Bereichen;
- die NVRAM-Variablen eines Dumps mit ihren Werten auflisten, nach ihrem Typ gelesen, und die Variablen zweier Dumps nach Name und GUID gegenüberstellen: welche nur einer von beiden enthält, welche sich unterscheiden und in welchen Bytes. Dumps verschiedener Boards oder BIOS-Versionen lassen sich ebenso vergleichen wie zwei Dumps eines Boards, und ein ganzer Ordner von Dumps lässt sich auf einmal mit einem davon vergleichen;
- Bytes markieren, während er sie erklärt: ein gestrichelter Rahmen in eigener Farbe mit einer kurzen Bezeichnung; ruht der Zeiger auf den markierten Bytes, erscheint die Erläuterung des Agenten. Eine Markierung kann andere nennen, auf die sie sich bezieht — einen Zeiger und sein Ziel, eine Prüfsumme und die Bytes, die sie abdeckt;
- eine Datei über ihren Pfad öffnen, ohne sie anzuzeigen, und allen Dumps eines Ordners auf einmal dieselbe Frage stellen — wie viele Kopien einer Variablen jeder enthält, an welcher Adresse eine Struktur beginnt —, mit den Antworten nach Wert gruppiert. Eine so geöffnete Datei wird nur gelesen; gibt es darin etwas zu zeigen, öffnet der Agent sie in einem eigenen Tab;
- Befunde festhalten: jeweils ein Satz und die Stelle, auf die er sich bezieht; das Agentenfenster listet sie auf;
- einen Werkzeugbereich für ein Dokument öffnen, wie es das Menü **Werkzeuge** tut, und im geöffneten Bereich **UEFI-Struktur** einen Knoten wählen. Der Baum öffnet sich bis zum Knoten, und der Dump scrollt zu seinen Bytes.

Jede Stelle, die ein Agent zeigt, jeder Bereich, den er öffnet, und jeder Knoten, den er wählt, ist ein Schritt des Verlaufs: **Darstellung ▸ Zurück** (**⌘[**) kehrt dorthin zurück, wo die Ansicht vorher war ([[topic:navigation|Sich bewegen]]).

Eine Datei sichern kann ein Agent nicht; ändern kann er sie nur, wenn es erlaubt ist (siehe unten). Adressen in seinen Antworten sind hexadezimal, wie im Dump.

## Änderungen durch den Agenten erlauben

**Agenten das Ändern geöffneter Dateien erlauben** in **Einstellungen ▸ Agent** ist nach der Installation ausgeschaltet und unabhängig von dem Schalter, der die Verbindung erlaubt. Solange er ausgeschaltet ist, nennt ein Agent, der etwas ändern soll, stattdessen die Änderung, die er vornehmen würde.

Ist er eingeschaltet, kann ein Agent:

- Bytes in einer Datei überschreiben, die in einem Tab geöffnet ist. Ein Schreibvorgang ersetzt genau so viele Bytes, wie er enthält, und fügt nie Bytes ein oder entfernt sie; er lässt sich an die Bedingung knüpfen, dass an der Adresse bestimmte Bytes stehen;
- eine Prüfsumme korrigieren — die eines Volumes, einer Datei oder eines Microcodes in **UEFI-Struktur**, die der Tabelle in **FIT-Tabelle** — mit demselben Code wie der Befehl **Prüfsumme korrigieren** der Bereiche.

Jede Änderung ist ein Schritt des Widerrufens der Datei, benannt mit **Agent:** und der Beschreibung des Agenten; **Bearbeiten ▸ Widerrufen** (**⌘Z**) nimmt sie zurück. Die geänderten Bytes sind bis zum Sichern rot markiert, wie bei einer Änderung von Hand, und der Dump scrollt zu ihnen, als Schritt des Verlaufs. Gesichert wird die Datei nur vom Benutzer. Eine schreibgeschützt geöffnete Datei und eine Datei, die der Agent ohne Tab über ihren Pfad geöffnet hat, werden nie geändert.

## Das Agentenfenster

**Fenster ▸ Agent** zeigt, ob der Dienst läuft, und enthält zwei Listen.

**Protokoll** listet jede Anfrage des Agenten auf: Uhrzeit, Werkzeug, die Argumente so, wie der Agent sie geschrieben hat, Antwortzeit, Größe der Antwort und Ergebnis. Eine abgelehnte Anfrage erscheint rot, mit dem Grund, der dem Agenten genannt wurde. **Protokoll leeren** leert die Liste; nach dem Beenden des Programms wird sie nicht aufbewahrt.

**Markierungen** listet die Markierungen auf, die der Agent in allen geöffneten Dateien gesetzt hat: Bezeichnung, Datei, Bytes, Erläuterung und die Markierungen, auf die sie sich bezieht. Ein Doppelklick auf eine Zeile holt ihre Datei nach vorn und wählt ihre Bytes aus, als Schritt des Verlaufs. **Markierung entfernen** entfernt die gewählten Zeilen, **Alle Markierungen entfernen** alle. Eine Markierung verschwindet auch, wenn ihre Datei geschlossen wird oder der Agent sie entfernt.

**Befunde** listet auf, was der Agent gefunden hat und wo: den Satz, die Datei, die Bytes oder den Knoten. Ein Doppelklick öffnet die Datei an dieser Stelle — im Tab, der sie schon zeigt, oder in einem neuen. **Alle Befunde entfernen** leert die Liste.

## Dateien außerhalb der geöffneten Fenster

Liest der Agent zum ersten Mal einen Ordner, den macOS schützt — Schreibtisch, Dokumente, Downloads —, fragt macOS, ob ByteRipper darauf zugreifen darf. Die Anfrage des Agenten wartet auf die Antwort; das übrige Programm nicht. Die Antwort gilt für ByteRipper fortan, wie jede andere Erlaubnis, die das Programm erfragt.

## Wenn der Dienst nicht startet

Die Statuszeile unter **Einstellungen ▸ Agent** nennt den Grund. Meist läuft bereits eine zweite Kopie von ByteRipper mit eingeschaltetem Dienst: Agenten bedienen kann immer nur eine Kopie, und die zweite lässt die Verbindung der ersten unangetastet.
