@source-sha 6478dac1b8866fb62514abd277350ceb9f99751ef93d718e991734914dfdb320
# Intel-CPUID-Suche

> Ein Fenster, das die Tabelle der Intel-Prozessoren nach CPUID, Modell, S-SPEC, Codename oder Stepping durchsucht – dieselbe Tabelle, nach der das FIT-Werkzeug Prozessoren benennt.

**Fenster ▸ Intel-CPUID-Suche** öffnet ein eigenes Fenster. Es gehört zu keinem Dump und kann neben ihnen geöffnet bleiben. Es beantwortet die Fragen, die bei einer Reparatur zu einem Prozessor entstehen: welche CPUID ein Chip mit einer bestimmten S-SPEC hat, welche Modelle hinter der CPUID eines Microcodes stehen und welche weiteren Prozessoren dasselbe Microcode-Update bedient.

## Suchen

Geben Sie den Suchbegriff in das Suchfeld ein. Die Tabelle darunter führt jedes passende Modell mit CPUID, S-SPEC-Codes, Stepping und Codename auf. Groß- und Kleinschreibung, Leerzeichen und Satzzeichen werden nicht berücksichtigt: `i72600k`, `i7 2600K` und `Core i7-2600K` finden dasselbe Modell. Mehrere Wörter grenzen die Suche ein; jedes Wort muss in der Zeile vorkommen, etwa `xeon 906EA`. Eine CPUID, die die Tabelle mit `X` schreibt, etwa `606AX`, steht für jede CPUID mit einer beliebigen Hexadezimalziffer an dieser Stelle und wird über jede von ihnen gefunden. Die Treffer sind in jeder Zeile markiert.

Während der Eingabe bietet eine Liste unter dem Feld Vervollständigungen an – CPUIDs, S-SPEC-Codes, Modelle und Codenamen, jeweils mit ihrer Zuordnung. **↑** und **↓** bewegen sich durch die Liste, **Return** übernimmt den gewählten Eintrag, **Escape** schließt die Liste; ein Klick übernimmt einen Eintrag direkt. Die Lupe im Feld öffnet die letzten zehn Suchen. Eine Suche wird gespeichert, wenn **Return** gedrückt oder eine Vervollständigung übernommen wird, oder wenn sie etwas gefunden hat und zwei Sekunden unverändert geblieben ist. **Suchverlauf löschen** im selben Menü entfernt sie.

Ein Klick auf eine Spaltenüberschrift sortiert die Tabelle nach dieser Spalte, ein zweiter Klick kehrt die Reihenfolge um. Ein Doppelklick auf eine Zeile sucht nach ihrer CPUID.

## Eine vollständig eingegebene CPUID

Ist die Eingabe genau eine CPUID, wird über den Modellen alles angezeigt, was die Tabelle über sie weiß: Codenamen, Steppings, Produktfamilie, Segment, Kerne und die Anzahl der Modelle. **Gemeinsamer Microcode** führt die Microcode-Updates auf, die über ihre erweiterte Signaturtabelle auch andere CPUIDs bedienen, jeweils mit Revision und Datum; ein Klick auf eine dieser CPUIDs sucht nach ihr. Für CPUIDs, die anhand von Intels eigenen Dokumenten in die Tabelle aufgenommen wurden, nennen **Anmerkungen** und **Quellen** die Begründung (auf Englisch) und die Seiten, denen jede Angabe entnommen wurde, mit der zitierten Zeile; ein Klick auf eine Seite öffnet sie im Browser. Führt die Tabelle für die CPUID keine Modelle auf, zeigt das Fenster nur diese Angaben. Eine CPUID ohne Eintrag in der Tabelle, die aber ein Microcode-Update nennt, wird ebenfalls angezeigt – zusammen mit den Updates, die sie bedienen.

## Kopieren

**Bearbeiten ▸ Kopieren** kopiert die ausgewählten Zeilen, eine Textzeile je Tabellenzeile, die Spalten durch Tabulatoren getrennt. Das Kontextmenü einer Zeile bietet außerdem **S-SPEC kopieren**, **Modell kopieren** und **CPUID suchen**.

## Woher die Tabelle stammt

Die Tabelle liegt im öffentlichen Repository `github.com/maxshevelev/IntelCPUID`, demselben, das unter [[topic:tool-fit|FIT-Tabelle]] beschrieben ist. Der Link unten im Fenster öffnet es; das Datum daneben ist der Tag, an dem ihre Quellen zuletzt abgeglichen wurden. Das Fenster und das FIT-Werkzeug lesen ein und dieselbe Kopie: Beim Öffnen eines von beiden fragt das Programm höchstens einmal täglich beim Repository nach, ob sich die Tabelle geändert hat, und eine neuere Tabelle erscheint nach dem Laden in beiden. Die letzte vollständig gelesene Kopie wird auf diesem Mac aufbewahrt; ohne Netzwerk wird sie durchsucht. Solange noch keine Kopie gelesen wurde, meldet das Fenster dies und findet nichts. Siehe auch [[topic:databases|Die Online-Kataloge]].

Die Tabelle ist nicht vollständig, und das wird nicht verschwiegen: Ein Modell mit unbekannter S-SPEC wird mit einem Strich aufgeführt, und eine CPUID, die sie nicht enthält, wird nicht gefunden. Sie führt jedes Modell auf, das mit einer CPUID verkauft wurde, unabhängig von der Plattform einer bestimmten Platine.
