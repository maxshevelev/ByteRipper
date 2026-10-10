@source-sha b606594cc98163e06d36b81f4e6dcf09e1cbdf3932ce677733efd35478bffdff
# Mit einem Agenten arbeiten

> An ByteRipper lässt sich ein Agent anbinden: Claude Code, Claude Desktop oder ein anderes Programm, das das Protokoll MCP unterstützt. Der angebundene Agent hat Zugriff auf die in ByteRipper geöffneten Dateien, liest deren Inhalt und zeigt die betreffenden Stellen im Dump an. Die Unterhaltung mit dem Agenten selbst findet im Fenster seines eigenen Programms statt.

Agent und Techniker arbeiten mit denselben Fenstern. Fragen Sie den Agenten nach „diesem“ Byte, ermittelt er es aus der Position des Cursors und der Auswahl. Bezieht er sich seinerseits auf eine Stelle im Dump, scrollt er die Ansicht dorthin und wählt die betreffenden Bytes aus. Beide Seiten sprechen so über dieselben Daten, ohne Adressen in Worten austauschen zu müssen.

## Dienst einschalten

Im Auslieferungszustand ist der Agentendienst ausgeschaltet. Eingeschaltet wird er unter **Einstellungen ▸ Agent** mit der Option **Agenten die Verbindung mit ByteRipper erlauben**. Solange der Dienst läuft, zeigt die Menüleiste von macOS ein Symbol dafür an: drei durch eine gepunktete Linie verbundene Punkte. Wartet der Dienst auf einen Agenten, ist das Symbol abgeblendet; ist ein Agent verbunden, sind die Punkte ausgefüllt. Die Taste für das Agentenfenster in der Symbolleiste zeigt den Zustand auf dieselbe Weise. Das ist bei einem Mac mit Kameraaussparung von Bedeutung: Ist die Menüleiste voll belegt, verschwindet ihr rechter Teil hinter der Aussparung.

Die Verbindung ist ausschließlich lokal; ein Netzwerkport wird nicht geöffnet. ByteRipper legt dazu im Ordner „Library“ des Benutzers eine Datei an, die nur Programmen desselben Benutzerkontos zugänglich ist.

Zu beachten ist jedoch: Die Bytes, die der Agent liest, übermittelt sein Programm an das Sprachmodell, auf dem der Agent beruht — im Fall von Claude an den Dienst von Anthropic. Öffnen Sie daher keinen Dump, der die Werkstatt nicht verlassen darf, solange ein Agent verbunden ist.

## Programm des Agenten einrichten

Unter **Einstellungen ▸ Agent** legt das Menü **Konfiguration für:** fest, in welchem Programm der Agent ausgeführt wird. Darunter erscheint der vollständige Konfigurationstext für dieses Programm zusammen mit dem Hinweis, wo er einzutragen ist; **Kopieren** übernimmt ihn in die Zwischenablage.

- **Claude Code** — ein Befehl für das Terminal. Er muss nur einmal ausgeführt werden; danach steht ByteRipper in Claude Code in jedem Ordner zur Verfügung.
- **Claude Desktop** — ein JSON-Block für die Konfigurationsdatei `~/Library/Application Support/Claude/claude_desktop_config.json`. Claude Desktop wertet diese Datei beim Start aus.
- **Cursor** — derselbe JSON-Block, einzutragen in `~/.cursor/mcp.json` für alle Projekte oder in `.cursor/mcp.json` für ein einzelnes Projekt.
- **Anderer Client** — die Verbindungsparameter einzeln: Name `byteripper`, Transport `stdio` und der Befehl; Argumente und Umgebungsvariablen sind nicht erforderlich. Diese Variante ist für Clients bestimmt, die die Parameter in einem eigenen Formular abfragen.

Enthält die Konfigurationsdatei bereits andere Server, wird der Eintrag `byteripper` neben ihnen in denselben Abschnitt `mcpServers` eingefügt.

Jede Variante enthält den Pfad zum Hilfsprogramm innerhalb genau dieser Kopie von ByteRipper. Nach dem Verschieben von ByteRipper in einen anderen Ordner ist der Konfigurationstext daher neu zu kopieren.

Ist ByteRipper beim Start des Agentenprogramms nicht geöffnet, startet das Hilfsprogramm es selbstständig. Ist der Dienst dagegen ausgeschaltet, meldet das Agentenprogramm, dass der Agentendienst von ByteRipper nicht läuft.

## Warum nicht über HTTP

Manche Programme, darunter Claude Desktop, binden einen über HTTP erreichbaren Server direkt in ihren Einstellungen ein — ohne Konfigurationsdatei und ohne Neustart. ByteRipper bietet einen solchen Server bewusst nicht an:

- Ein Server über HTTP wartet an einem Netzwerkport, und jedes Programm auf dem Computer kann ihn erreichen, auch im Browser geöffnete Webseiten. Er bräuchte ein eigenes Passwort, das in der Konfiguration des Agenten steht, und Schutz vor Anfragen von Webseiten. Die Datei, die ByteRipper in der Library des Benutzers anlegt, erreichen nur Programme desselben Benutzerkontos; es gibt nichts einzurichten und nichts, was nach außen gelangen könnte.
- Ein Agent liest Dumps und ändert sie, wenn es erlaubt ist. Der Zugang zu ihm ist daher nicht weiter gefasst als der Zugang zu den Dumps selbst.
- Das Programm des Agenten startet das Hilfsprogramm selbst. Dieses startet ByteRipper, wenn es nicht läuft, und meldet, wenn der Dienst ausgeschaltet ist; ein Server über HTTP wäre in beiden Fällen schlicht nicht erreichbar.

Der Preis dafür ist die oben beschriebene Einrichtung, einmal je Programm, und eine Verbindung nur vom selben Computer aus: Ein Agent, der auf einem anderen Computer läuft, kann sich nicht verbinden.

## Dateien lesen

Der Agent kann:

- die geöffneten Dateien mit Name und Größe auflisten und angeben, ob ungesicherte Änderungen vorliegen;
- die Position des Cursors, die Grenzen der Auswahl und die auf dem Bildschirm sichtbaren Zeilen abfragen;
- Bytes als Hex-Zeilen, als Text oder als 16-, 32- und 64-Bit-Zahlen lesen, einschließlich ungesicherter Änderungen;
- eine Datei über ihren Pfad öffnen, ohne sie anzuzeigen. Eine solche Datei wird ausschließlich gelesen; enthält sie etwas, das gezeigt werden sollte, öffnet der Agent sie in einem eigenen Tab;
- allen Dumps eines Ordners gleichzeitig dieselbe Frage stellen — etwa, wie viele Kopien einer Variablen jeder Dump enthält oder an welcher Adresse eine Struktur beginnt — und die Antworten nach Wert gruppiert erhalten.

Adressen gibt der Agent stets hexadezimal an, wie im Dump.

## Aufbau der Firmware

Der Agent liest ein Firmware-Image in derselben Aufschlüsselung wie die Werkzeugbereiche; geöffnet sein müssen die Bereiche dafür nicht.

- **UEFI-Struktur** — der Baum des Images, die Felder eines Knotens und die Knoten, in die eine bestimmte Adresse fällt. Der Baum lässt sich nach Name, GUID oder Typ durchsuchen. Die Felder eines Knotens sind dieselben wie in den Details des Bereichs, einschließlich des Dateinamens aus dem GUID-Katalog. Der Agent prüft außerdem alle Prüfsummen des Images auf einmal — die eines Volumes, einer Datei, eines Microcodes, eines PSP-Verzeichnisses — und nennt die falschen mit dem richtigen Wert, wie es die roten Markierungen im Bereich tun. Auch die Bytes eines einzelnen Knotens kann der Agent lesen, selbst wenn dieser in einem komprimierten Abschnitt liegt.
- **FIT-Tabelle** — die Einträge der Tabelle, die Objekte, auf die sie verweisen, und die verletzten Regeln der Spezifikation.
- **ME Analyzer** — Übersicht und dekodierte Struktur der Intel-ME-Firmware.
- NVRAM-Variablen — die Variablen eines Dumps mit ihren Werten, ausgewertet gemäß ihrem Typ.

## Dumps vergleichen

- Bytevergleich zweier Dateien, wie ihn auch die beiden Bereiche des Fensters durchführen: an gleichen Adressen, ohne verschobene Daten auszurichten. Das Ergebnis ist entweder eine Liste der abweichenden Abschnitte mit dem jeweiligen Teil der Firmware (Region, Volume, Variable, ME-Partition oder ME-Datei) oder eine Übersicht über Regionen, Volumes und ME-Partitionen, die auch die unveränderten aufführt.
- Vergleich der NVRAM-Variablen zweier Dumps nach Name und GUID: welche Variablen nur ein Dump enthält, welche sich unterscheiden und in welchen Bytes. Verglichen werden können nicht nur zwei Dumps desselben Boards, sondern auch Dumps verschiedener Boards oder BIOS-Versionen.
- Vergleich der Dateien in den ME-Dateisystemen (MFS und EFS) zweier Dumps nach ihrer Nummer im Volume und nach ihrem Inhalt statt nach ihrer Adresse: welche Dateien übereinstimmen, welche sich unterscheiden und in wie vielen Bytes, welche nur in einem Dump vorhanden sind.
- Öffnen eines Dateiabschnitts oder Knotens als eigener Teil über der Datei, wie mit **Zone öffnen**. So lassen sich zwei Blöcke an unterschiedlichen Adressen jeweils ab ihrem ersten Byte vergleichen.
- Anzeige zweier Dateien nebeneinander — als Paar in einem neuen Tab oder neben einer Datei, die allein in ihrem Tab geöffnet ist — mit Sprung von Abweichung zu Abweichung wie über die entsprechenden Pfeile im Fenster.

Bytevergleich und Variablenvergleich lassen sich auch für einen ganzen Ordner von Dumps gegen einen davon in einem Schritt ausführen.

Der dateiweise Vergleich der ME-Dateisysteme ist erforderlich, weil ein MFS- oder EFS-Volume seine Daten umlagert, um den Speicherchip gleichmäßig abzunutzen. In zwei Dumps desselben Geräts kann eine Datei deshalb an verschiedenen Adressen stehen: Der Bytevergleich der Partition zeigt dann lediglich umgelagerte Daten, der Dateivergleich hingegen, welche Dateien sich tatsächlich geändert haben. Die Integrity-Tabelle am Ende einer geschützten Datei wird gesondert verglichen, da die ME-Engine sie bei jedem erneuten Schreiben der Datei aktualisiert. Ein Volume, das sich in einem der Dumps nicht lesen ließ, wird als nicht verglichen ausgewiesen; seine Dateien gelten nicht als fehlend.

## Suchen

Der Agent sucht in einer Datei nach Text oder nach einer Bytefolge. Text wird als ASCII oder UTF-16 ohne Unterscheidung von Groß- und Kleinschreibung gesucht; in einer Bytefolge steht `??` für ein beliebiges Byte. Die Suche erstreckt sich auch auf die komprimierten Abschnitte eines Firmware-Images, die in der Datei nur in komprimierter Form vorliegen. Zu jedem Treffer wird der Teil der Firmware angegeben, in dem er sich befindet.

Der Agent findet außerdem, wer in einem Firmware-Image auf eine Adresse oder eine GUID verweist: die Module, in deren Code sie vorkommt — in der Datei selbst und in komprimierten Abschnitten —, gruppiert nach FFS-Dateien. Eine Adresse wird in drei Formen gesucht: so, wie der Prozessor sie sieht (die BIOS-Region liegt unterhalb der 4-GB-Grenze), als Adresse in der Datei und als Offset in der BIOS-Region. Eine Übereinstimmung von vier Bytes im Code kann zufällig sein; deshalb ist bei jeder angegeben, in welcher Form sie gefunden wurde.

Bereiche, denen der Parser keinen Namen geben kann — Füllbereiche, ungenutzte und unbekannte Bereiche der Flash-Karte, Raw-Dateien —, beurteilt der Agent nach ihrem Inhalt: leer, Text, Daten oder Code, mit einigen der darin gefundenen Zeichenketten. Für einen Bereich, den die Flash-Karte MSDM, Password oder Key nennt, werden keine Zeichenketten ausgegeben, und die Suche zeigt keine Bytes um einen Treffer darin.

## Wie der Agent Ergebnisse zeigt

- Stelle anzeigen: Der Agent holt den Tab der Datei nach vorn, scrollt den Dump an die betreffende Stelle und wählt sie aus.
- Werkzeugbereiche: Der Agent öffnet einen Bereich für ein Dokument wie über das Menü **Werkzeuge** und wählt im geöffneten Bereich **UEFI-Struktur** einen Knoten aus; der Baum wird bis zu diesem Knoten aufgeklappt, und der Dump scrollt zu dessen Bytes.
- Markierungen: Während der Agent Bytes erläutert, umgibt er sie mit einem gestrichelten Rahmen in eigener Farbe und versieht sie mit einer kurzen Bezeichnung; verweilt der Zeiger über den markierten Bytes, erscheint die Erläuterung des Agenten. Eine Markierung kann auf zugehörige Markierungen verweisen — etwa ein Zeiger auf sein Ziel oder eine Prüfsumme auf die Daten, über die sie gebildet wird. Solche Markierungen folgen auf die Erläuterung, nach **Zugehörige Markierungen:**, mit Nummer und Bezeichnung.
- Befunde: Jeder Befund besteht aus einer Aussage und der Stelle, auf die sie sich bezieht. Das Agentenfenster führt alle Befunde auf.

Jede vom Agenten angezeigte Stelle, jeder von ihm geöffnete Bereich und jeder von ihm gewählte Knoten wird im Verlauf festgehalten. Mit **Darstellung ▸ Zurück** (**⌘[**) kehren Sie zur vorherigen Ansicht zurück ([[topic:navigation|Sich bewegen]]).

Sichern kann der Agent keine Datei; ändern darf er sie nur mit Ihrer Erlaubnis.

## Änderungen durch den Agenten zulassen

Die Option **Agenten das Ändern geöffneter Dateien erlauben** unter **Einstellungen ▸ Agent** ist im Auslieferungszustand ausgeschaltet und von der Option für die Verbindung unabhängig. Solange sie ausgeschaltet ist, beschreibt der Agent auf die Bitte um eine Änderung lediglich, welche Änderung er vornehmen würde.

Ist sie eingeschaltet, kann der Agent:

- Bytes in einer Datei überschreiben, die in einem Tab geöffnet ist. Ein Schreibvorgang ersetzt genau so viele Bytes, wie er mitbringt, und fügt niemals Bytes ein oder entfernt welche. Er lässt sich an die Bedingung knüpfen, dass an der Adresse derzeit bestimmte Bytes stehen;
- einen Abschnitt einer der beiden Dateien eines Tabs an dieselben Adressen der anderen kopieren, wie es **Bearbeiten ▸ In den anderen Bereich kopieren** mit der Auswahl tut. Die Bytes gehen innerhalb von ByteRipper von Datei zu Datei und nicht über den Agenten, sodass sich eine ganze Region auf einmal kopieren lässt; die Antwort nennt, wie viele Bytes sich tatsächlich geändert haben. Ein Kopieren über das Ende der anderen Datei hinaus und in eine schreibgeschützt geöffnete Datei wird abgelehnt;
- Prüfsummen korrigieren — die eines Volumes, einer Datei, eines Microcodes oder eines PSP-Verzeichnisses in **UEFI-Struktur** und die der Tabelle in **FIT-Tabelle**. Die Berechnung erfolgt mit demselben Code wie beim Befehl **Prüfsumme korrigieren** der Bereiche. In **UEFI-Struktur** kann der Agent alle falschen Prüfsummen auf einmal korrigieren, als einen Schritt des Widerrufens; eine Datei, die ein Volume enthält, wird nach den Dateien darin korrigiert. Eine Prüfsumme in einem komprimierten Abschnitt wird nicht geändert: Die Datei enthält diese Bytes komprimiert;
- Microcode in der FIT hinzufügen, aktualisieren, ersetzen und entfernen, und zwar aus demselben Online-Katalog, den **FIT-Tabelle** anbietet, und mit denselben Prüfungen. Ein Update, das unter einer anderen seiner CPUIDs bereits in der Tabelle steht, wird abgelehnt. Ein Update, dessen erweiterte Signaturtabelle einen Prozessor abdeckt, für den bereits ein Eintrag zuständig ist, tritt an die Stelle dieses Eintrags. Ein Ersatz, nach dem einem Prozessor zwei Microcodes zugeordnet wären, wird abgelehnt, wobei der zu ersetzende Eintrag genannt wird;
- ermitteln, für welche Microcodes des Images der Katalog eine neuere Revision bereithält.

Jede Änderung des Agenten bildet einen eigenen Schritt im Widerrufen-Verlauf der Datei. Der Schritt trägt die Bezeichnung **Agent:** und die Beschreibung, die der Agent der Änderung gegeben hat; **Bearbeiten ▸ Widerrufen** (**⌘Z**) nimmt ihn zurück. Bis zum Sichern erscheinen die geänderten Bytes rot, wie bei einer Änderung von Hand; der Dump scrollt zu ihnen, und dieser Sprung wird im Verlauf festgehalten. Gesichert wird eine Datei ausschließlich vom Benutzer. Eine schreibgeschützt geöffnete Datei sowie eine Datei, die der Agent ohne Tab über ihren Pfad geöffnet hat, werden niemals verändert.

## Das Agentenfenster

**Fenster ▸ Agent** zeigt den Zustand des Dienstes und enthält vier Listen. Solange der Dienst eingeschaltet ist, befindet sich in der Symbolleiste zwischen **?** und dem Umschalter für die Anordnung der Bereiche eine Taste für dieses Fenster, mit demselben Symbol wie der Reiter „Agent“ in den Einstellungen. Sie öffnet das Agentenfenster oder holt es nach vorn, falls es bereits geöffnet ist. Die Tastatur wirkt danach auf die Liste der angezeigten Seite; die Pfeiltasten bewegen die Auswahl durch ihre Zeilen. Beim Wechsel auf eine andere Seite geht die Tastatur auf deren Liste über.

**Protokoll** verzeichnet jede Anfrage des Agenten mit Uhrzeit, Werkzeug, den Argumenten in der vom Agenten übergebenen Form, Antwortzeit, Größe der Antwort und Ergebnis. Abgelehnte Anfragen sind rot dargestellt, zusammen mit dem Grund, der dem Agenten mitgeteilt wurde.

In der Tabelle werden lange Argumente gekürzt. Die Liste darunter zeigt die ausgewählte Anfrage vollständig: Uhrzeit, Client, Antwortzeit, Größe der Antwort in Bytes, das vollständige Ergebnis und unter **Argumente** das gesamte vom Agenten gesendete JSON, ein Element pro Zeile. Der Text dieser Liste lässt sich auswählen und kopieren. Die **Leertaste** im Protokoll oder die Taste in der Ecke der Liste vergrößert die Liste über das ganze Fenster, wie bei den Details eines Werkzeugbereichs; **Leertaste** oder **Esc** verkleinert sie wieder.

Ist **Neuen Anfragen folgen** unter dem Protokoll eingeschaltet, scrollt das Protokoll zu jeder eintreffenden Anfrage; andernfalls behält es seine Position bei. Eine ausgewählte Anfrage bleibt auch beim Eintreffen neuer Anfragen ausgewählt. **Protokoll leeren** entfernt alle Einträge; nach dem Beenden des Programms wird das Protokoll nicht aufbewahrt.

**Markierungen** führt die Markierungen auf, die der Agent in allen geöffneten Dateien gesetzt hat: Bezeichnung, Datei, Bytes und Erläuterung; zugehörige Markierungen stehen nach der Erläuterung, hinter **Zugehörige Markierungen:**. Ein Doppelklick auf eine Zeile holt die Datei nach vorn und wählt die markierten Bytes aus; dieser Sprung wird im Verlauf festgehalten. **Markierung entfernen** entfernt die ausgewählten Zeilen, **Alle Markierungen entfernen** sämtliche Markierungen. Darüber hinaus verschwindet eine Markierung, wenn ihre Datei geschlossen wird oder der Agent sie selbst entfernt.

**Befunde** führt auf, was der Agent gefunden hat und wo: Aussage, Datei, Bytes oder Knoten. Ein Doppelklick öffnet die Datei an dieser Stelle — in dem Tab, in dem sie bereits geöffnet ist, oder in einem neuen. **Alle Befunde entfernen** leert die Liste.

**Werkzeuge** listet jedes Werkzeug auf, das dem Agenten angeboten wird, in Abschnitten; die Überschrift eines Abschnitts nennt, woher die Werkzeuge stammen: ein Teil von ByteRipper oder ein Bereich wie **UEFI-Struktur**. Zu jedem Werkzeug stehen Name und Art: **Lesen** ändert nichts, **Anzeige** ändert, was das Fenster zeigt (die Ansicht, eine Markierung, einen Befund, einen Tab), **Ändert eine Datei** schreibt in eine geöffnete Datei. Daneben die Nutzung seit dem Start von ByteRipper: die Aufrufe, die Aufrufe **Ohne Antwort**, die durchschnittliche Dauer, der Umfang der Antworten und der letzte Aufruf. Die Liste darunter zeigt das ausgewählte Werkzeug so, wie der Agent es beschrieben bekommt: die **Beschreibung** und unter **Argumente** die Argumente als JSON-Schema, beide auf Englisch, wie der Agent sie liest. **Statistik zurücksetzen** setzt die Zähler auf null; nach dem Beenden des Programms werden sie nicht aufbewahrt.

## Zugriff auf Ordner außerhalb der geöffneten Fenster

Greift der Agent erstmals auf einen von macOS geschützten Ordner zu — „Schreibtisch“, „Dokumente“, „Downloads“ —, fragt macOS, ob ByteRipper darauf zugreifen darf. Die Anfrage des Agenten wartet auf die Antwort, das übrige Programm bleibt währenddessen bedienbar. macOS speichert die Antwort für ByteRipper wie jede andere vom Programm erfragte Berechtigung.

## Wenn der Dienst nicht startet

Die Statuszeile unter **Einstellungen ▸ Agent** nennt die Ursache. In den meisten Fällen läuft bereits eine weitere Kopie von ByteRipper mit eingeschaltetem Dienst. Es kann jeweils nur eine Kopie Agenten bedienen; die zweite lässt die Verbindung der ersten unangetastet.
