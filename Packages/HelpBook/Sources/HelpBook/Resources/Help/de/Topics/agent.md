@source-sha 2c7cf430733d36d115aad229cfa73262954dd2cc024614bd394fe7c3132773f7
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

## Warum nicht über HTTP

Manche Programme, darunter Claude Desktop, binden einen über HTTP erreichbaren Server direkt in ihren Einstellungen ein — ohne Konfigurationsdatei und ohne Neustart. ByteRipper bietet einen solchen Server bewusst nicht an:

- Ein Server über HTTP wartet an einem Netzwerkport, und jedes Programm auf dem Computer kann ihn erreichen, auch im Browser geöffnete Webseiten. Er bräuchte ein eigenes Passwort, das in der Konfiguration des Agenten steht, und Schutz vor Anfragen von Webseiten. Die Datei, die ByteRipper in der Library des Benutzers anlegt, erreichen nur Programme desselben Benutzerkontos; es gibt nichts einzurichten und nichts, was nach außen gelangen könnte.
- Ein Agent liest Dumps und ändert sie, wenn es erlaubt ist. Der Zugang zu ihm ist daher nicht weiter gefasst als der Zugang zu den Dumps selbst.
- Das Programm des Agenten startet das Hilfsprogramm selbst. Dieses startet ByteRipper, wenn es nicht läuft, und meldet, wenn der Dienst ausgeschaltet ist; ein Server über HTTP wäre in beiden Fällen schlicht nicht erreichbar.

Der Preis dafür ist die oben beschriebene Einrichtung, einmal je Programm, und eine Verbindung nur vom selben Computer aus: Ein Agent, der auf einem anderen Computer läuft, kann sich nicht verbinden.

## Was ein Agent kann

Derzeit kann ein Agent:

- die geöffneten Dateien auflisten, mit Namen, Größe und der Angabe, ob ungesicherte Änderungen vorliegen;
- die Position des Cursors, die Auswahl und die sichtbaren Zeilen abfragen;
- Bytes lesen — als Hex-Zeilen, als Text oder als 16-, 32- und 64-Bit-Zahlen —, ungesicherte Änderungen eingeschlossen;
- eine Stelle zeigen: ihren Tab nach vorn holen, dorthin scrollen und sie auswählen;
- die Struktur eines Firmware-Images so lesen, wie **UEFI-Struktur** sie zeigt — den Baum, die Felder eines Knotens, die Knoten, die eine Adresse enthalten — und darin nach Name, GUID oder Typ suchen. Das geht unabhängig davon, ob der Bereich geöffnet ist;
- die FIT-Tabelle so lesen, wie **FIT-Tabelle** sie zeigt — ihre Einträge, worauf jeder verweist, welche Regeln der Spezifikation sie verletzt —, und die Intel-ME-Firmware so, wie **ME Analyzer** sie zeigt: die Übersicht und die dekodierte Struktur. Auch das geht bei geschlossenen Bereichen;
- die NVRAM-Variablen eines Dumps mit ihren Werten auflisten, nach ihrem Typ gelesen, und die Variablen zweier Dumps nach Name und GUID gegenüberstellen: welche nur einer von beiden enthält, welche sich unterscheiden und in welchen Bytes. Dumps verschiedener Boards oder BIOS-Versionen lassen sich ebenso vergleichen wie zwei Dumps eines Boards, und ein ganzer Ordner von Dumps lässt sich auf einmal mit einem davon vergleichen;
- die Dateien der ME-Dateisysteme (MFS und EFS) zweier Dumps nach ihrer Nummer im Volume und nach Inhalt gegenüberstellen, nicht nach Adresse: welche gleich sind, welche sich unterscheiden und in wie vielen Bytes, welche nur ein Dump enthält. Das Volume verlagert seine Daten, um den Speicherchip gleichmäßig abzunutzen; in zwei Dumps eines Geräts kann dieselbe Datei daher an verschiedenen Adressen liegen. Ein Bytevergleich der Partition zeigt dann verlagerte Daten, dieser Vergleich dagegen, welche Dateien sich geändert haben. Die Integrity-Tabelle am Ende einer geschützten Datei wird getrennt verglichen: Sie ändert sich jedes Mal, wenn die Engine die Datei neu schreibt. Ein Volume, das in einem der Dumps nicht gelesen werden konnte, wird als nicht verglichen genannt, und seine Dateien gelten nicht als fehlend;
- Bytes markieren, während er sie erklärt: ein gestrichelter Rahmen in eigener Farbe mit einer kurzen Bezeichnung; ruht der Zeiger auf den markierten Bytes, erscheint die Erläuterung des Agenten. Eine Markierung kann andere nennen, auf die sie sich bezieht — einen Zeiger und sein Ziel, eine Prüfsumme und die Bytes, die sie abdeckt;
- eine Datei über ihren Pfad öffnen, ohne sie anzuzeigen, und allen Dumps eines Ordners auf einmal dieselbe Frage stellen — wie viele Kopien einer Variablen jeder enthält, an welcher Adresse eine Struktur beginnt —, mit den Antworten nach Wert gruppiert. Eine so geöffnete Datei wird nur gelesen; gibt es darin etwas zu zeigen, öffnet der Agent sie in einem eigenen Tab;
- Befunde festhalten: jeweils ein Satz und die Stelle, auf die er sich bezieht; das Agentenfenster listet sie auf;
- zwei Dateien Byte für Byte vergleichen, wie es der Vergleich zweier Bereiche tut — an denselben Adressen, ohne verschobene Daten auszurichten. Die Antwort ist entweder eine Liste der abweichenden Abschnitte, jeweils mit dem Teil der Firmware, in dem er liegt (Region, Volume, Variable, ME-Partition oder ME-Datei), oder eine Übersicht über Regionen, Volumes und ME-Partitionen, die auch die unveränderten nennt. Ein ganzer Ordner von Dumps lässt sich auf einmal mit einem davon vergleichen;
- einen Text oder Bytes in einer Datei finden — als ASCII oder UTF-16, ohne Beachtung der Groß- und Kleinschreibung, mit `??` für ein beliebiges Byte —, auch innerhalb der komprimierten Abschnitte eines Firmware-Abbilds, die die Datei nur komprimiert enthält; zu jedem Treffer wird der Teil der Firmware genannt, in dem er liegt;
- die Bytes eines Knotens der **UEFI-Struktur** lesen, auch eines Knotens in einem komprimierten Abschnitt, und einen Abschnitt der Datei oder einen Knoten als Teil über der Datei öffnen, wie es **Zone öffnen** tut, damit zwei Blöcke an verschiedenen Adressen von ihrem Anfang an verglichen werden;
- zwei Dateien als Paar nebeneinander in einem neuen Tab zeigen — oder neben einer Datei, die allein in ihrem Tab ist — und ihre Abweichungen so durchgehen, wie es die Pfeile zum Navigieren zwischen Abweichungen im Fenster tun;
- einen Werkzeugbereich für ein Dokument öffnen, wie es das Menü **Werkzeuge** tut, und im geöffneten Bereich **UEFI-Struktur** einen Knoten wählen. Der Baum öffnet sich bis zum Knoten, und der Dump scrollt zu seinen Bytes.

Jede Stelle, die ein Agent zeigt, jeder Bereich, den er öffnet, und jeder Knoten, den er wählt, ist ein Schritt des Verlaufs: **Darstellung ▸ Zurück** (**⌘[**) kehrt dorthin zurück, wo die Ansicht vorher war ([[topic:navigation|Sich bewegen]]).

Eine Datei sichern kann ein Agent nicht; ändern kann er sie nur, wenn es erlaubt ist (siehe unten). Adressen in seinen Antworten sind hexadezimal, wie im Dump.

## Änderungen durch den Agenten erlauben

**Agenten das Ändern geöffneter Dateien erlauben** in **Einstellungen ▸ Agent** ist nach der Installation ausgeschaltet und unabhängig von dem Schalter, der die Verbindung erlaubt. Solange er ausgeschaltet ist, nennt ein Agent, der etwas ändern soll, stattdessen die Änderung, die er vornehmen würde.

Ist er eingeschaltet, kann ein Agent:

- Bytes in einer Datei überschreiben, die in einem Tab geöffnet ist. Ein Schreibvorgang ersetzt genau so viele Bytes, wie er enthält, und fügt nie Bytes ein oder entfernt sie; er lässt sich an die Bedingung knüpfen, dass an der Adresse bestimmte Bytes stehen;
- eine Prüfsumme korrigieren — die eines Volumes, einer Datei oder eines Microcodes in **UEFI-Struktur**, die der Tabelle in **FIT-Tabelle** — mit demselben Code wie der Befehl **Prüfsumme korrigieren** der Bereiche;
- Microcode in der FIT aus demselben Online-Katalog, den **FIT-Tabelle** anbietet, hinzufügen, aktualisieren, ersetzen und entfernen, mit denselben Prüfungen. Ein Update, das unter einer anderen seiner CPUIDs schon in der Tabelle steht, wird abgelehnt. Ein Update, dessen erweiterte Signaturtabelle einen Prozessor bedient, den schon eine Zeile bedient, tritt an die Stelle dieser Zeile. Ein Ersatz, nach dem ein Prozessor zwei Microcodes hätte, wird abgelehnt, und die zu ersetzende Zeile wird genannt. Der Agent gibt außerdem an, für welche Microcodes des Abbilds der Katalog eine neuere Revision hat.

Jede Änderung ist ein Schritt des Widerrufens der Datei, benannt mit **Agent:** und der Beschreibung des Agenten; **Bearbeiten ▸ Widerrufen** (**⌘Z**) nimmt sie zurück. Die geänderten Bytes sind bis zum Sichern rot markiert, wie bei einer Änderung von Hand, und der Dump scrollt zu ihnen, als Schritt des Verlaufs. Gesichert wird die Datei nur vom Benutzer. Eine schreibgeschützt geöffnete Datei und eine Datei, die der Agent ohne Tab über ihren Pfad geöffnet hat, werden nie geändert.

## Das Agentenfenster

**Fenster ▸ Agent** zeigt, ob der Dienst läuft, und enthält drei Listen. Solange der Dienst eingeschaltet ist, hat die Symbolleiste zwischen **?** und dem Umschalter für die Anordnung der Bereiche eine Taste dafür, mit dem Symbol des Reiters „Agent“ in den Einstellungen; sie öffnet das Fenster oder holt es nach vorn, wenn es schon offen ist.

**Protokoll** listet jede Anfrage des Agenten auf: Uhrzeit, Werkzeug, die Argumente so, wie der Agent sie geschrieben hat, Antwortzeit, Größe der Antwort und Ergebnis. Eine abgelehnte Anfrage erscheint rot, mit dem Grund, der dem Agenten genannt wurde. Lange Argumente werden in der Tabelle gekürzt; die Liste darunter zeigt die ausgewählte Anfrage vollständig: Uhrzeit, Client, Antwortzeit, Größe der Antwort in Bytes, das vollständige Ergebnis und unter **Argumente** das gesamte JSON, das der Agent gesendet hat, ein Element je Zeile. Ihr Text lässt sich auswählen und kopieren. Die **Leertaste** im Protokoll oder die Taste in der Ecke der Liste öffnet sie groß über dem Fenster, wie die Details eines Werkzeugbereichs; **Leertaste** oder **Esc** schließt sie wieder. **Neuen Anfragen folgen** unter dem Protokoll scrollt es zu jeder neuen Anfrage; ist es ausgeschaltet, bleibt das Protokoll, wo es gelassen wurde. Die ausgewählte Anfrage bleibt ausgewählt, wenn neue eintreffen. **Protokoll leeren** leert die Liste; nach dem Beenden des Programms wird sie nicht aufbewahrt.

**Markierungen** listet die Markierungen auf, die der Agent in allen geöffneten Dateien gesetzt hat: Bezeichnung, Datei, Bytes, Erläuterung und die Markierungen, auf die sie sich bezieht. Ein Doppelklick auf eine Zeile holt ihre Datei nach vorn und wählt ihre Bytes aus, als Schritt des Verlaufs. **Markierung entfernen** entfernt die gewählten Zeilen, **Alle Markierungen entfernen** alle. Eine Markierung verschwindet auch, wenn ihre Datei geschlossen wird oder der Agent sie entfernt.

**Befunde** listet auf, was der Agent gefunden hat und wo: den Satz, die Datei, die Bytes oder den Knoten. Ein Doppelklick öffnet die Datei an dieser Stelle — im Tab, der sie schon zeigt, oder in einem neuen. **Alle Befunde entfernen** leert die Liste.

## Dateien außerhalb der geöffneten Fenster

Liest der Agent zum ersten Mal einen Ordner, den macOS schützt — Schreibtisch, Dokumente, Downloads —, fragt macOS, ob ByteRipper darauf zugreifen darf. Die Anfrage des Agenten wartet auf die Antwort; das übrige Programm nicht. Die Antwort gilt für ByteRipper fortan, wie jede andere Erlaubnis, die das Programm erfragt.

## Wenn der Dienst nicht startet

Die Statuszeile unter **Einstellungen ▸ Agent** nennt den Grund. Meist läuft bereits eine zweite Kopie von ByteRipper mit eingeschaltetem Dienst: Agenten bedienen kann immer nur eine Kopie, und die zweite lässt die Verbindung der ersten unangetastet.
