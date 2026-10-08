@source-sha 594adcaeba013a30bfb4071125e3f281c750a5c7ee1b4ad1818f4c5752720b43
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
- einen Werkzeugbereich für ein Dokument öffnen, wie es das Menü **Werkzeuge** tut, und im geöffneten Bereich **UEFI-Struktur** einen Knoten wählen. Der Baum öffnet sich bis zum Knoten, und der Dump scrollt zu seinen Bytes.

Jede Stelle, die ein Agent zeigt, jeder Bereich, den er öffnet, und jeder Knoten, den er wählt, ist ein Schritt des Verlaufs: **Darstellung ▸ Zurück** (**⌘[**) kehrt dorthin zurück, wo die Ansicht vorher war ([[topic:navigation|Sich bewegen]]).

Eine Datei sichern oder ändern kann ein Agent nicht. Adressen in seinen Antworten sind hexadezimal, wie im Dump.

## Das Agentenfenster

**Fenster ▸ Agent** zeigt, ob der Dienst läuft, und listet jede Anfrage des Agenten auf: Uhrzeit, Werkzeug, die Argumente so, wie der Agent sie geschrieben hat, Antwortzeit, Größe der Antwort und Ergebnis. Eine abgelehnte Anfrage erscheint rot, mit dem Grund, der dem Agenten genannt wurde. **Protokoll leeren** leert die Liste; nach dem Beenden des Programms wird sie nicht aufbewahrt.

## Wenn der Dienst nicht startet

Die Statuszeile unter **Einstellungen ▸ Agent** nennt den Grund. Meist läuft bereits eine zweite Kopie von ByteRipper mit eingeschaltetem Dienst: Agenten bedienen kann immer nur eine Kopie, und die zweite lässt die Verbindung der ersten unangetastet.
